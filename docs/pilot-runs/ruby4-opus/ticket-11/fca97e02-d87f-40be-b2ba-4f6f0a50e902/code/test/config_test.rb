# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  Config = Syncbox::Server::Config

  def test_flags
    config = Config.parse(["--data-dir", "/srv/data", "--port", "9000"], {})

    assert_equal "/srv/data", config.data_dir
    assert_equal 9000, config.port
  end

  def test_flags_with_equals_sign
    config = Config.parse(["--data-dir=/srv/data", "--port=9000"], {})

    assert_equal "/srv/data", config.data_dir
    assert_equal 9000, config.port
  end

  def test_port_defaults_to_8080
    assert_equal 8080, Config.parse(["--data-dir", "/srv/data"], {}).port
  end

  def test_environment_variables
    config = Config.parse([], { "SYNCBOX_DATA_DIR" => "/env/data", "SYNCBOX_PORT" => "9001" })

    assert_equal "/env/data", config.data_dir
    assert_equal 9001, config.port
  end

  def test_flags_take_precedence_over_environment
    env = { "SYNCBOX_DATA_DIR" => "/env/data", "SYNCBOX_PORT" => "9001" }
    config = Config.parse(["--data-dir", "/flag/data", "--port", "9002"], env)

    assert_equal "/flag/data", config.data_dir
    assert_equal 9002, config.port
  end

  def test_empty_environment_variables_are_ignored
    config = Config.parse(["--data-dir", "/srv/data"], { "SYNCBOX_DATA_DIR" => "", "SYNCBOX_PORT" => "" })

    assert_equal 8080, config.port
    assert_raises(Config::Error) { Config.parse([], { "SYNCBOX_DATA_DIR" => "" }) }
  end

  def test_relative_data_dir_is_expanded
    Dir.chdir(Dir.tmpdir) do
      assert_equal File.join(Dir.pwd, "data"), Config.parse(["--data-dir", "data"], {}).data_dir
    end
  end

  def test_data_dir_is_required
    error = assert_raises(Config::Error) { Config.parse(["--port", "9000"], {}) }
    assert_match(/--data-dir/, error.message)
    assert_match(/SYNCBOX_DATA_DIR/, error.message)
  end

  def test_invalid_ports_are_rejected
    ["0", "65536", "-1", "80a", "8080.0", "0x50", " 80", ""].each do |port|
      assert_raises(Config::Error, "port #{port.inspect}") do
        Config.parse(["--data-dir", "/srv/data", "--port", port], {})
      end
    end
    assert_raises(Config::Error) { Config.parse([], { "SYNCBOX_DATA_DIR" => "/d", "SYNCBOX_PORT" => "http" }) }
  end

  def test_port_bounds_are_accepted
    assert_equal 1, Config.parse(["--data-dir", "/d", "--port", "1"], {}).port
    assert_equal 65_535, Config.parse(["--data-dir", "/d", "--port", "65535"], {}).port
  end

  def test_unknown_and_malformed_arguments_are_rejected
    [
      ["--data-dir", "/d", "--verbose"],
      ["--data-dir", "/d", "extra"],
      ["--data", "/d"],
      ["--data-dir"],
      ["--data-dir", "/d", "--port"],
    ].each do |argv|
      assert_raises(Config::Error, argv.inspect) { Config.parse(argv, {}) }
    end
  end

  def test_help
    assert_raises(Config::HelpRequested) { Config.parse(["--help"], {}) }
    assert_raises(Config::HelpRequested) { Config.parse(["-h"], {}) }
  end

  def test_prepare_data_dir_creates_missing_directories
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "a", "b")
      Config.new(data_dir: path, port: "8080").prepare_data_dir!

      assert File.directory?(path)
    end
  end

  def test_prepare_data_dir_rejects_a_regular_file
    Dir.mktmpdir do |tmp|
      path = File.join(tmp, "file")
      File.write(path, "")

      error = assert_raises(Config::Error) { Config.new(data_dir: path, port: "8080").prepare_data_dir! }
      assert_match(/not a directory/, error.message)
    end
  end

  def test_prepare_data_dir_rejects_a_read_only_directory
    skip "root ignores permission bits" if Process.uid.zero?

    Dir.mktmpdir do |tmp|
      File.chmod(0o555, tmp)
      assert_raises(Config::Error) { Config.new(data_dir: tmp, port: "8080").prepare_data_dir! }
      assert_raises(Config::Error) { Config.new(data_dir: File.join(tmp, "sub"), port: "8080").prepare_data_dir! }
    ensure
      File.chmod(0o755, tmp)
    end
  end
end
