# frozen_string_literal: true

require "test_helper"
require "net/http"
require "open3"

# Интеграционные тесты: запускают настоящий bin/syncbox-server как отдельный
# процесс, ходят в него по HTTP и проверяют корректное завершение по SIGTERM.
class ServerIntegrationTest < Minitest::Test
  include Syncbox::TestSupport

  def setup
    @tmp = Dir.mktmpdir("syncbox-test")
    @pid = nil
  end

  def teardown
    if @pid && Process.waitpid(@pid, Process::WNOHANG).nil?
      Process.kill("KILL", @pid)
      Process.wait(@pid)
    end
  rescue Errno::ECHILD, Errno::ESRCH
    # процесс уже завершился и был забран самим тестом
  ensure
    FileUtils.remove_entry(@tmp) if @tmp && File.exist?(@tmp)
  end

  def spawn_server(*args, env: {})
    log = File.join(@tmp, "server.log")
    base_env = { "SYNCBOX_DATA_DIR" => nil, "SYNCBOX_PORT" => nil }
    @pid = Process.spawn(base_env.merge(env), SERVER_BIN, *args, out: log, err: log)
    @log = log
    @pid
  end

  def test_healthz_over_http_with_flags
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)

    response = wait_for_healthz(port, pid: @pid)
    assert_equal "200", response.code
    assert_equal({ "status" => "ok" }, JSON.parse(response.body))
    assert File.directory?(data_dir), "server should create its data dir"

    Process.kill("TERM", @pid)
    _, status = Process.wait2(@pid)
    assert status.success?, "server should exit cleanly on SIGTERM, got #{status.inspect}\n#{File.read(@log)}"
  end

  def test_configuration_via_environment_variables
    port = free_port
    data_dir = File.join(@tmp, "env-data")
    spawn_server(env: { "SYNCBOX_DATA_DIR" => data_dir, "SYNCBOX_PORT" => port.to_s })

    response = wait_for_healthz(port, pid: @pid)
    assert_equal "200", response.code
    assert File.directory?(data_dir)
  end

  def test_blob_endpoints_over_http
    port = free_port
    spawn_server("--data-dir", File.join(@tmp, "data"), "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    # Ровно как в отчёте проверки: PUT без тела с octet-stream и GET списка.
    response = http.request(Net::HTTP::Put.new("/blobs/0", "content-type" => "application/octet-stream"))
    assert_equal "201", response.code, response.body
    assert_equal({ "key" => "0", "sha256" => Digest::SHA256.hexdigest(""), "size" => 0 }, JSON.parse(response.body))

    response = http.get("/blobs")
    assert_equal "200", response.code
    assert_equal ["0"], JSON.parse(response.body).map { |m| m["key"] }

    payload = (0..255).map(&:chr).join.b * 1000
    request = Net::HTTP::Put.new("/blobs/dir/data.bin", "content-type" => "application/octet-stream")
    request.body = payload
    response = http.request(request)
    assert_equal "201", response.code
    assert_equal Digest::SHA256.hexdigest(payload), JSON.parse(response.body)["sha256"]

    response = http.get("/blobs/dir/data.bin")
    assert_equal "200", response.code
    assert_equal payload, response.body.b

    assert_equal "400", http.request(Net::HTTP::Put.new("/blobs/../escape")).code
    assert_equal "400", http.request(Net::HTTP::Put.new("/blobs/%ed%a0%80")).code
    assert_equal "404", http.get("/blobs/nope").code

    assert_equal "204", http.delete("/blobs/dir/data.bin").code
    assert_equal "404", http.delete("/blobs/dir/data.bin").code
  end

  def test_list_blobs_over_http
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    response = http.get("/blobs")
    assert_equal "200", response.code
    assert_match %r{\Aapplication/json}, response["content-type"]
    assert_equal [], JSON.parse(response.body)

    { "docs/readme.txt" => "hello", "a.bin" => "\x00\xff".b, "x/y/z" => "" }.each do |key, body|
      request = Net::HTTP::Put.new("/blobs/#{key}", "content-type" => "application/octet-stream")
      request.body = body
      assert_equal "201", http.request(request).code
    end
    FileUtils.mkdir_p(File.join(data_dir, "ext"))
    File.binwrite(File.join(data_dir, "ext", "on-disk"), "disk")

    response = http.get("/blobs")
    assert_equal "200", response.code
    list = JSON.parse(response.body)
    assert_equal ["a.bin", "docs/readme.txt", "ext/on-disk", "x/y/z"], list.map { |m| m["key"] }

    expected = { "docs/readme.txt" => "hello", "a.bin" => "\x00\xff".b, "x/y/z" => "", "ext/on-disk" => "disk" }
    list.each do |meta|
      content = expected.fetch(meta["key"])
      assert_equal content.bytesize, meta["size"], meta.inspect
      assert_equal Digest::SHA256.hexdigest(content), meta["sha256"], meta.inspect
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, meta["modified_at"])
      assert_in_delta Time.now.to_f, Time.iso8601(meta["modified_at"]).to_f, 60
    end

    # HEAD /blobs — как GET, но без тела.
    response = http.head("/blobs")
    assert_equal "200", response.code
    assert_nil response.body
  end

  def test_delete_blob_over_http
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)

    %w[docs/readme.txt docs/other.txt top].each do |key|
      request = Net::HTTP::Put.new("/blobs/#{key}", "content-type" => "application/octet-stream")
      request.body = key
      assert_equal "201", http.request(request).code
    end

    response = http.delete("/blobs/docs/readme.txt")
    assert_equal "204", response.code
    assert_nil response.body
    assert_nil response["content-type"]
    refute File.exist?(File.join(data_dir, "docs", "readme.txt"))

    assert_equal "404", http.get("/blobs/docs/readme.txt").code
    assert_equal "404", http.delete("/blobs/docs/readme.txt").code
    assert_equal ["docs/other.txt", "top"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
    assert_equal "docs/other.txt", http.get("/blobs/docs/other.txt").body

    assert_equal "204", http.delete("/blobs/docs/other.txt").code
    refute File.exist?(File.join(data_dir, "docs")), "empty docs/ should be pruned"
    assert_equal "404", http.delete("/blobs/missing").code
    assert_equal "404", http.delete("/blobs/no/such/dir/file").code
    assert_equal ["top"], JSON.parse(http.get("/blobs").body).map { |m| m["key"] }
  end

  # Сырой HTTP-запрос в обход Net::HTTP (он мог бы нормализовать путь или
  # отказаться отправлять мусорные байты). Возвращает полный ответ сервера.
  def raw_request(port, request_line, body: nil)
    socket = TCPSocket.new("127.0.0.1", port)
    headers = ["Host: 127.0.0.1", "Connection: close"]
    headers << "Content-Length: #{body.bytesize}" if body
    socket.write("#{request_line}\r\n#{headers.join("\r\n")}\r\n\r\n#{body}")
    socket.read
  ensure
    socket&.close
  end

  def test_directory_traversal_is_rejected_over_http
    port = free_port
    data_dir = File.join(@tmp, "data")
    FileUtils.mkdir_p(data_dir)
    canary = File.join(@tmp, "canary")
    File.binwrite(canary, "canary")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)
    outside_before = Dir.children(@tmp).sort

    # Полностью «открытые» формы: Net::HTTP отправляет путь как есть.
    %w[/blobs/../canary /blobs/../../etc/passwd /blobs/a/../../canary /blobs//etc/passwd /blobs/./canary].each do |path|
      put = Net::HTTP::Put.new(path, "content-type" => "application/octet-stream")
      put.body = "pwned"
      response = http.request(put)
      assert_equal "400", response.code, "PUT #{path}"
      assert_equal "invalid_key", JSON.parse(response.body)["error"]
      assert_equal "400", http.get(path).code, "GET #{path}"
      assert_equal "400", http.delete(path).code, "DELETE #{path}"
    end

    # Закодированные и битые формы — сырым сокетом, байт в байт.
    [
      "/blobs/%2e%2e/canary",
      "/blobs/..%2fcanary",
      "/blobs/%2e%2e%2f%2e%2e%2fetc%2fpasswd",
      "/blobs/a/%2e./canary",
      "/blobs/%2fetc%2fpasswd",
      "/blobs/%c0%ae%c0%ae/canary",
      "/blobs/%ed%a0%80",
      "/blobs/%ff",
      "/blobs/a%00/../canary"
    ].each do |path|
      %w[PUT GET DELETE].each do |method|
        response = raw_request(port, "#{method} #{path} HTTP/1.1", body: method == "PUT" ? "pwned" : nil)
        assert_match(%r{\AHTTP/1\.[01] 400 }, response, "#{method} #{path}\n#{response}")
      end
    end

    # Непредставимые байты прямо в строке запроса (без percent-encoding):
    # сервер отвечает 400 или закрывает соединение, но не падает и не 5xx.
    ["/blobs/\xff\xfe".b, "/blobs/a\x00b".b, "/blobs/\xed\xa0\x80".b].each do |path|
      response = raw_request(port, "PUT #{path} HTTP/1.1", body: "pwned")
      refute_match(%r{\AHTTP/1\.[01] 5}, response.to_s, "PUT #{path.inspect}\n#{response}")
      assert_match(%r{\A(HTTP/1\.[01] 400 |\z)}, response.to_s, "PUT #{path.inspect}\n#{response}")
    end

    # Symlink внутри каталога данных, ведущий наружу.
    File.symlink(@tmp, File.join(data_dir, "escape"))
    put = Net::HTTP::Put.new("/blobs/escape/pwned", "content-type" => "application/octet-stream")
    put.body = "pwned"
    assert_equal "400", http.request(put).code
    assert_equal "400", http.get("/blobs/escape/canary").code
    assert_equal "400", http.delete("/blobs/escape/canary").code
    assert_equal [], JSON.parse(http.get("/blobs").body)

    # Сервер жив, снаружи каталога данных ничего не появилось и не пропало.
    assert_equal "200", http.get("/healthz").code
    assert_equal "canary", File.binread(canary)
    assert_equal outside_before, Dir.children(@tmp).sort
    assert_equal [], Dir.children(data_dir) - [Syncbox::Store::TMP_DIR, "escape"]

    # А обычный вложенный key при этом работает.
    put = Net::HTTP::Put.new("/blobs/docs/readme.txt", "content-type" => "application/octet-stream")
    put.body = "ok"
    assert_equal "201", http.request(put).code
    assert_equal "ok", http.get("/blobs/docs/readme.txt").body
  end

  def test_missing_data_dir_fails_fast_with_usage_error
    _out, err, status = Open3.capture3({ "SYNCBOX_DATA_DIR" => nil }, SERVER_BIN)
    assert_equal 2, status.exitstatus
    assert_match(/--data-dir is required/, err)
  end

  # --- тикет 6: атомарность записи при параллельных PUT ------------------------

  def put_blob(http, key, body)
    request = Net::HTTP::Put.new("/blobs/#{key}", "content-type" => "application/octet-stream")
    request.body = body
    http.request(request)
  end

  # Начинает загрузку и рвёт соединение, не дослав тело.
  def abort_upload(port, key, headers, partial_body)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.write("PUT /blobs/#{key} HTTP/1.1\r\nHost: 127.0.0.1\r\n#{headers.join("\r\n")}\r\n\r\n")
    socket.write(partial_body)
  ensure
    socket&.close
  end

  def wait_until(timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
    true
  end

  def drain(queue)
    Array.new(queue.size) { queue.pop }
  end

  def test_concurrent_puts_to_the_same_key_over_http_never_expose_partial_content
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)

    size = 512 * 1024 + 7
    versions = ("A".."F").map { |c| c.b * size }
    assert_equal "201", put_blob(Net::HTTP.new("127.0.0.1", port), "hot", versions.first).code

    problems = Queue.new
    reads = Queue.new
    done = false

    writers = versions.each_slice(2).map do |mine|
      Thread.new do
        Net::HTTP.start("127.0.0.1", port) do |http|
          2.times do
            mine.each do |version|
              response = put_blob(http, "hot", version)
              ok = response.code == "201" && JSON.parse(response.body)["sha256"] == Digest::SHA256.hexdigest(version)
              problems << "PUT -> #{response.code} #{response.body}" unless ok
            end
          end
        end
      rescue StandardError => e
        problems << e
      end
    end

    readers = 3.times.map do
      Thread.new do
        Net::HTTP.start("127.0.0.1", port) do |http|
          until done
            response = http.get("/blobs/hot")
            body = response.body.to_s.b
            ok = response.code == "200" && response["content-length"].to_i == body.bytesize && versions.include?(body)
            unless ok
              problems << "GET -> #{response.code}, #{body.bytesize} bytes, " \
                          "head #{body[0, 4].inspect}, tail #{body[-4..].inspect}"
            end
            reads << 1
          end
        end
      rescue StandardError => e
        problems << e
      end
    end

    writers.each(&:join)
    done = true
    readers.each(&:join)

    assert_empty drain(problems)
    assert_operator reads.size, :>, 0, "readers must have raced the writers"

    http = Net::HTTP.new("127.0.0.1", port)
    final = http.get("/blobs/hot").body.b
    assert_includes versions, final, "the final content is one complete version"
    assert_equal [["hot", size, Digest::SHA256.hexdigest(final)]],
                 JSON.parse(http.get("/blobs").body).map { |m| m.values_at("key", "size", "sha256") }
    assert_empty Dir.children(File.join(data_dir, Syncbox::Store::TMP_DIR))
  end

  def test_concurrent_puts_to_different_keys_over_http_do_not_interfere
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)

    payload_for = ->(t, i) { "#{t}/#{i}:".b + Random.new(t * 1000 + i).bytes(70_000 + i) }
    key_for = ->(t, i) { "dir#{t % 2}/sub#{t}/file-#{i}.bin" }
    problems = Queue.new

    threads = 6.times.map do |t|
      Thread.new do
        Net::HTTP.start("127.0.0.1", port) do |http|
          15.times do |i|
            payload = payload_for.call(t, i)
            response = put_blob(http, key_for.call(t, i), payload)
            expected = { "key" => key_for.call(t, i), "sha256" => Digest::SHA256.hexdigest(payload), "size" => payload.bytesize }
            ok = response.code == "201" && JSON.parse(response.body) == expected
            problems << "PUT #{key_for.call(t, i)} -> #{response.code} #{response.body}" unless ok
          end
        end
      rescue StandardError => e
        problems << e
      end
    end
    threads.each(&:join)
    assert_empty drain(problems)

    http = Net::HTTP.new("127.0.0.1", port)
    6.times do |t|
      15.times do |i|
        assert_equal payload_for.call(t, i), http.get("/blobs/#{key_for.call(t, i)}").body.b, key_for.call(t, i)
      end
    end
    list = JSON.parse(http.get("/blobs").body)
    assert_equal 90, list.length
    list.each do |meta|
      t, i = meta["key"].match(%r{sub(\d+)/file-(\d+)\.bin\z}).captures.map(&:to_i)
      payload = payload_for.call(t, i)
      assert_equal [payload.bytesize, Digest::SHA256.hexdigest(payload)], meta.values_at("size", "sha256"), meta["key"]
    end
    assert_empty Dir.children(File.join(data_dir, Syncbox::Store::TMP_DIR))
  end

  def test_aborted_upload_keeps_the_previous_version_and_leaves_no_temp_file
    port = free_port
    data_dir = File.join(@tmp, "data")
    spawn_server("--data-dir", data_dir, "--port", port.to_s)
    wait_for_healthz(port, pid: @pid)
    http = Net::HTTP.new("127.0.0.1", port)
    tmp_dir = File.join(data_dir, Syncbox::Store::TMP_DIR)
    assert_equal "201", put_blob(http, "docs/k", "previous").code

    # Content-Length обещает мегабайт, клиент шлёт 100 KiB и рвёт соединение.
    abort_upload(port, "docs/k", ["Content-Type: application/octet-stream", "Content-Length: 1048576"], "X" * (100 * 1024))
    # То же в chunked-кодировании: один чанк и обрыв без завершающего нулевого.
    abort_upload(port, "docs/k", ["Transfer-Encoding: chunked"], "400\r\n#{'Y' * 1024}\r\n")
    # И по ключу, которого ещё нет.
    abort_upload(port, "gone/never", ["Content-Length: 1000000"], "partial")

    assert wait_until { Dir.children(tmp_dir).empty? }, "temp files must not outlive an aborted request: #{Dir.children(tmp_dir)}"
    assert_equal "previous", http.get("/blobs/docs/k").body
    assert_equal "404", http.get("/blobs/gone/never").code
    refute File.exist?(File.join(data_dir, "gone")), "nothing is created for a blob that never arrived"
    assert_equal [["docs/k", 8, Digest::SHA256.hexdigest("previous")]],
                 JSON.parse(http.get("/blobs").body).map { |m| m.values_at("key", "size", "sha256") }
    assert_equal "200", http.get("/healthz").code

    # Сервер по-прежнему принимает загрузки по тому же ключу.
    assert_equal "201", put_blob(http, "docs/k", "after").code
    assert_equal "after", http.get("/blobs/docs/k").body
    assert_empty Dir.children(tmp_dir)
  end
end
