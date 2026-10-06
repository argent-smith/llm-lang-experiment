# frozen_string_literal: true

require "test_helper"
require "stringio"

# Юнит-тесты защиты key от directory traversal (тикет 5): лексическая
# проверка и проверка итогового пути после разрешения символических ссылок.
class StoreKeyTest < Minitest::Test
  InvalidKey = Syncbox::Store::InvalidKey
  NotFound = Syncbox::Store::NotFound

  def setup
    # Корень хранилища — подкаталог, чтобы «снаружи» был каталог-канарейка,
    # до которого traversal пытается добраться.
    @tmp = Dir.mktmpdir("syncbox-key")
    @data_dir = File.join(@tmp, "data")
    FileUtils.mkdir_p(@data_dir)
    @outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(@outside)
    @canary = File.join(@outside, "canary")
    File.binwrite(@canary, "canary")
    @store = Syncbox::Store.new(@data_dir)
  end

  def teardown
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def read_all(key)
    size, body = @store.open(key)
    chunks = []
    body.each { |chunk| chunks << chunk }
    [size, chunks.join]
  ensure
    body&.close
  end

  # Снимок всего дерева @tmp вне каталога данных: traversal не должен ничего
  # создать, изменить или удалить за пределами корня хранилища.
  def outside_snapshot
    Dir.glob("**/*", File::FNM_DOTMATCH, base: @tmp)
       .reject { |rel| rel == "." || rel == "data" || rel.start_with?("data/") }
       .sort
       .map { |rel| [rel, File.file?(File.join(@tmp, rel)) ? File.binread(File.join(@tmp, rel)) : :dir] }
  end

  def assert_invalid_everywhere(key, message = nil)
    before = outside_snapshot
    assert_raises(InvalidKey, "put #{key.inspect}") { @store.put(key, StringIO.new("pwned")) }
    assert_raises(InvalidKey, "open #{key.inspect}") { @store.open(key) }
    assert_raises(InvalidKey, "delete #{key.inspect}") { @store.delete(key) }
    assert_equal before, outside_snapshot, message || "nothing outside the data dir may change for #{key.inspect}"
    assert_equal "canary", File.binread(@canary)
  end

  # --- лексическая проверка -------------------------------------------------

  TRAVERSAL_KEYS = {
    "parent only" => "..",
    "parent at start" => "../outside/canary",
    "parent in the middle" => "a/../../outside/canary",
    "parent at end" => "a/..",
    "many parents" => "../../../../../../etc/passwd",
    "parent after valid dir" => "docs/../../outside/canary",
    "absolute" => "/etc/passwd",
    "double leading slash" => "//etc/passwd",
    "current dir segment" => "./a",
    "current dir in the middle" => "a/./b",
    "empty segment" => "a//b",
    "trailing slash" => "a/",
    "empty" => "",
    "NUL" => "a\0b",
    "NUL then parent" => "a\0/../../outside/canary"
  }.freeze

  TRAVERSAL_KEYS.each do |name, key|
    define_method("test_rejects_#{name.tr(' ', '_')}") do
      assert_invalid_everywhere(key)
    end
  end

  def test_rejects_absolute_path_to_a_real_file_outside_root
    assert_invalid_everywhere(@canary)
    assert_invalid_everywhere(File.join(@outside, "new-file"))
  end

  def test_rejects_invalid_utf8_including_overlong_dot_encodings
    # 0xC0 0xAE — «overlong» кодировка точки: после декодирования URL такие
    # байты невалидны в UTF-8, их нельзя безопасно превратить в имя файла.
    overlong_parent = "\xC0\xAE\xC0\xAE/outside/canary".b
    assert_invalid_everywhere(overlong_parent)
    assert_invalid_everywhere("\xFF".b)
    assert_invalid_everywhere("a/\xED\xA0\x80".b) # суррогат UTF-16
    assert_invalid_everywhere("\xC3".b)           # обрубленная многобайтовая последовательность
  end

  def test_rejects_segments_longer_than_name_max_and_paths_longer_than_path_max
    assert_invalid_everywhere("x" * 256)
    assert_invalid_everywhere(Array.new(40) { "s" * 200 }.join("/"))
    @store.put("x" * 255, StringIO.new("ok"))
    assert_equal [2, "ok"], read_all("x" * 255)
  end

  def test_validate_key_reports_the_reason
    error = assert_raises(InvalidKey) { @store.validate_key("../x") }
    assert_match(/'\.\.'/, error.message)
    error = assert_raises(InvalidKey) { @store.validate_key("/x") }
    assert_match(/relative/, error.message)
    error = assert_raises(InvalidKey) { @store.validate_key("\xFF".b) }
    assert_match(/UTF-8/, error.message)
  end

  def test_validate_key_does_not_normalize_the_key
    # Валидация ничего не вырезает: иначе «a/../..//x» после зачистки мог бы
    # стать валидным путём, а это и есть классический обход.
    assert_raises(InvalidKey) { @store.validate_key("a/..//x") }
    assert_equal "docs/readme.txt", @store.validate_key("docs/readme.txt")
    assert_equal Encoding::UTF_8, @store.validate_key("docs/readme.txt".b).encoding
  end

  # Имена, лишь похожие на traversal, — обычные файлы внутри корня.
  LOOKALIKE_KEYS = ["...", "..a", "a..", ".hidden", "a.../b...", "%2e%2e", "..%2f..%2fetc", "~", "~root/x",
                    "a\\..\\b", "a/..\\b", " ..", ".. ", "-", "--", "a/-/b"].freeze

  def test_accepts_keys_that_merely_look_like_traversal_and_keeps_them_inside_root
    LOOKALIKE_KEYS.each do |key|
      result = @store.put(key, StringIO.new(key))
      assert_equal key, result["key"]
      on_disk = File.join(@data_dir, key)
      assert File.file?(on_disk), "#{key.inspect} should be stored verbatim inside the data dir"
      assert_equal key, File.binread(on_disk)
      assert_equal [key.bytesize, key], read_all(key)
    end
    assert_equal LOOKALIKE_KEYS.sort, @store.list.map { |m| m["key"] }
    assert_equal "canary", File.binread(@canary)
    assert_equal ["canary"], Dir.children(@outside)
  end

  # --- проверка итогового пути (symlink) -------------------------------------

  def test_symlink_directory_pointing_outside_root_is_rejected_for_every_operation
    File.symlink(@outside, File.join(@data_dir, "escape"))

    assert_raises(InvalidKey) { @store.put("escape/pwned", StringIO.new("pwned")) }
    refute File.exist?(File.join(@outside, "pwned")), "PUT through an escaping symlink must not write outside"

    assert_raises(InvalidKey) { @store.open("escape/canary") }
    assert_raises(InvalidKey) { @store.delete("escape/canary") }
    assert_equal "canary", File.binread(@canary), "DELETE through an escaping symlink must not remove outside files"
    assert_raises(InvalidKey) { @store.open("escape/nested/missing") }
  end

  def test_symlink_file_pointing_outside_root_is_rejected_and_skipped_in_list
    File.symlink(@canary, File.join(@data_dir, "leak"))

    assert_raises(InvalidKey) { @store.open("leak") }
    assert_raises(InvalidKey) { @store.delete("leak") }
    assert File.symlink?(File.join(@data_dir, "leak"))
    assert_equal "canary", File.binread(@canary)
    assert_equal [], @store.list, "a symlink leading outside the root is not a blob"

    @store.put("regular", StringIO.new("r"))
    assert_equal ["regular"], @store.list.map { |m| m["key"] }
  end

  def test_put_over_symlink_file_pointing_outside_root_is_rejected
    File.symlink(@canary, File.join(@data_dir, "leak"))
    assert_raises(InvalidKey) { @store.put("leak", StringIO.new("pwned")) }
    assert_equal "canary", File.binread(@canary)
    assert File.symlink?(File.join(@data_dir, "leak")), "the symlink itself must be left alone"
  end

  def test_symlink_to_root_parent_is_judged_by_where_the_resolved_path_lands
    File.symlink(@tmp, File.join(@data_dir, "up"))
    @store.put("x", StringIO.new("x"))

    # Критерий — итоговый путь на диске: up/outside/canary разрешается наружу
    # и отклоняется, а up/data/x — обратно внутрь корня и остаётся допустимым.
    assert_raises(InvalidKey) { @store.open("up/outside/canary") }
    assert_raises(InvalidKey) { @store.delete("up/outside/canary") }
    assert_raises(InvalidKey) { @store.put("up/outside/pwned", StringIO.new("pwned")) }
    refute File.exist?(File.join(@outside, "pwned"))
    assert_equal "canary", File.binread(@canary)

    assert_equal [1, "x"], read_all("up/data/x")
  end

  def test_symlink_staying_inside_root_is_allowed
    @store.put("real/file", StringIO.new("inside"))
    File.symlink(File.join(@data_dir, "real"), File.join(@data_dir, "alias"))
    File.symlink("real/file", File.join(@data_dir, "alias-file")) # относительная ссылка

    assert_equal [6, "inside"], read_all("alias/file")
    assert_equal [6, "inside"], read_all("alias-file")
    @store.put("alias/new", StringIO.new("new"))
    assert_equal "new", File.binread(File.join(@data_dir, "real", "new"))
  end

  def test_dangling_symlink_is_not_found_and_put_replaces_the_link_itself
    File.symlink(File.join(@outside, "does-not-exist"), File.join(@data_dir, "dangling"))

    assert_raises(NotFound) { @store.open("dangling") }
    assert_raises(NotFound) { @store.delete("dangling") }

    @store.put("dangling", StringIO.new("now a file"))
    refute File.symlink?(File.join(@data_dir, "dangling")), "rename replaces the link, it does not follow it"
    assert_equal "now a file", File.binread(File.join(@data_dir, "dangling"))
    refute File.exist?(File.join(@outside, "does-not-exist"))
  end

  def test_symlink_loop_is_rejected_not_a_server_error
    File.symlink("loop", File.join(@data_dir, "loop"))

    assert_raises(InvalidKey) { @store.put("loop/x", StringIO.new("x")) }
    assert_raises(InvalidKey) { @store.open("loop/x") }
    assert_raises(InvalidKey) { @store.delete("loop/x") }
    assert_equal [], @store.list
  end

  def test_root_that_is_itself_a_symlink_works_normally
    real_root = File.join(@tmp, "real-root")
    FileUtils.mkdir_p(real_root)
    link_root = File.join(@tmp, "link-root")
    File.symlink(real_root, link_root)
    store = Syncbox::Store.new(link_root)

    store.put("docs/readme.txt", StringIO.new("hello"))
    assert_equal "hello", File.binread(File.join(real_root, "docs", "readme.txt"))
    size, body = store.open("docs/readme.txt")
    body.close
    assert_equal 5, size
    assert_equal ["docs/readme.txt"], store.list.map { |m| m["key"] }
    assert_raises(InvalidKey) { store.put("../outside/pwned", StringIO.new("pwned")) }
    assert_nil store.delete("docs/readme.txt")
  end

  def test_missing_root_is_created_on_first_access_instead_of_failing
    store = Syncbox::Store.new(File.join(@tmp, "fresh", "data"))
    assert_raises(NotFound) { store.open("x") }
    assert File.directory?(File.join(@tmp, "fresh", "data"))
    store.put("x", StringIO.new("x"))
    assert_equal ["x"], store.list.map { |m| m["key"] }
  end

  def test_path_for_rejects_path_that_lexically_escapes_root_even_if_validation_were_bypassed
    # Прямой вызов второго слоя: даже с «пропущенным» key путь наружу не выйдет.
    assert_raises(InvalidKey) { @store.send(:path_for, "../outside/canary") }
    assert_raises(InvalidKey) { @store.send(:path_for, "a/../../outside/canary") }
    assert_raises(InvalidKey) { @store.send(:path_for, "..") }
    assert_equal File.join(@data_dir, "ok", "fine"), @store.send(:path_for, "ok/fine")
  end
end
