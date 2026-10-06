# frozen_string_literal: true

require "fileutils"

module Syncbox
  # Разбор аргументов, подготовка каталога данных и запуск сервера.
  module CLI
    EXIT_OK = 0
    EXIT_FAILURE = 1
    EXIT_USAGE = 2

    module_function

    # Возвращает код завершения процесса.
    def run(argv, env: ENV, out: $stdout, err: $stderr)
      config = Config.parse(argv, env: env)
      prepare_data_dir(config.data_dir)
      Server.new(config, out: out, err: err).run
      EXIT_OK
    rescue Config::HelpRequested => e
      out.puts e.message
      EXIT_OK
    rescue Config::UsageError => e
      err.puts "syncbox-server: #{e.message}"
      err.puts Config.usage
      EXIT_USAGE
    rescue SystemCallError => e
      err.puts "syncbox-server: #{e.message}"
      EXIT_FAILURE
    end

    # Создаёт каталог данных при отсутствии и проверяет, что в него можно писать.
    def prepare_data_dir(path)
      FileUtils.mkdir_p(path)
      raise Errno::ENOTDIR, path unless File.directory?(path)
      raise Errno::EACCES, "data dir is not writable: #{path}" unless File.writable?(path)
    end
  end
end
