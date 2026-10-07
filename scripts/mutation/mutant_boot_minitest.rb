# frozen_string_literal: true

# Загрузчик для mutant-minitest: поднимает тесты реализации, не меняя её код.
#
# Каждому тестовому классу объявляется cover "Syncbox*" — на любую мутацию
# бежит весь набор тестов (до первого падения). Это намеренно: mutant берёт
# тесты с самым узким подходящим cover-выражением, и любая эвристика
# «класс теста -> константа» заслоняла бы остальные тесты (ConfigTest с
# cover Syncbox::Server::Config* вытеснял бы все тесты для субъектов
# Syncbox::Server::*). Score «по всему набору» одинаков по смыслу для всех
# реализаций и совпадает с тем, что считают языконезависимые инструменты.
root = Dir.pwd
$LOAD_PATH.unshift(File.join(root, "lib"), File.join(root, "test"))
require "minitest"
Minitest.seed ||= 1
# test_helper реализации вызывает minitest/autorun; его at_exit-раннер разбирал
# бы аргументы mutant и завершал killfork с ошибкой. Помечаем раннер
# установленным, чтобы autorun стал no-op: тесты запускает сам mutant.
Minitest.class_variable_set(:@@installed_at_exit, true)
require "mutant"
require "mutant/minitest/coverage"
require "mutant/integration/minitest"

# mutant-minitest 0.17 запускает тест через Minitest::Runnable.run_one_method,
# которого в Minitest 6 нет; запасной вызов Runnable.run(klass, method, reporter)
# молча ничего не запускает, и все мутации выживают. Запускаем тест напрямую.
if Gem::Version.new(Minitest::VERSION) >= Gem::Version.new("6")
  Mutant::Integration::Minitest.const_get(:TestCase).class_eval do
    def call(reporter)
      reporter.record(klass.new(test_method.to_s).run)
      reporter.passed?
    end
  end
end

require "test_helper"
Dir[File.join(root, "test", "**", "*_test.rb")].sort.each { |f| require f }
ObjectSpace.each_object(Class).select { |c| c < Minitest::Test }.each { |tc| tc.cover("Syncbox*") }
