# frozen_string_literal: true

# Загрузчик для mutant-rspec: тесты выбираются по константам в `describe`
# (RSpec.describe Syncbox::Config ...), объявлять ничего не нужно. Код
# реализации нужно загрузить до сопоставления субъектов: грузим все .rb
# из server/ и client/ (main.rb запускает сервер — его пропускаем; у
# реализации Sonnet файлы подключают друг друга через require_relative).
root = Dir.pwd
$LOAD_PATH.unshift(File.join(root, "lib"), File.join(root, "server"), File.join(root, "client"))
Dir[File.join(root, "{lib,server,client}", "**", "*.rb")].sort.each do |f|
  next if File.basename(f) == "main.rb"
  require f
end

# Как и для minitest: каждому примеру — выражение "Syncbox*", чтобы на любую
# мутацию бежал весь набор тестов, а не только группы с совпадающим describe.
# Так score считается одинаково для RSpec- и Minitest-реализаций.
require "mutant"
require "mutant/integration/rspec"
Mutant::Integration::Rspec.class_eval do
  def parse_metadata(_metadata)
    [parse_expression("Syncbox*")]
  end
end
