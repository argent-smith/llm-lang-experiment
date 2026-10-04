# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  Config = Syncbox::Server::Config
  ConfigError = Syncbox::Server::ConfigError

  def test_flags
    config = Config.parse(%w[--data-dir /srv/data --port 9000], {})
    assert_equal "/srv/data", config.data_dir
    assert_equal 9000, config.port
  end

  def test_flags_with_equals_sign
    config = Config.parse(%w[--data-dir=/srv/data --port=9000], {})
    assert_equal "/srv/data", config.data_dir
    assert_equal 9000, config.port
  end

  def test_port_defaults_to_8080
    assert_equal 8080, Config.parse(%w[--data-dir /srv/data], {}).port
  end

  def test_relative_data_dir_is_expanded
    assert_equal File.join(Dir.pwd, "data"), Config.parse(%w[--data-dir data], {}).data_dir
  end

  def test_environment_variables
    config = Config.parse([], "SYNCBOX_DATA_DIR" => "/env/data", "SYNCBOX_PORT" => "7000")
    assert_equal "/env/data", config.data_dir
    assert_equal 7000, config.port
  end

  def test_flags_take_precedence_over_environment
    env = { "SYNCBOX_DATA_DIR" => "/env/data", "SYNCBOX_PORT" => "7000" }
    config = Config.parse(%w[--data-dir /flag/data --port 9000], env)
    assert_equal "/flag/data", config.data_dir
    assert_equal 9000, config.port
  end

  def test_empty_environment_variables_are_treated_as_unset
    config = Config.parse(%w[--data-dir /srv/data], "SYNCBOX_DATA_DIR" => "", "SYNCBOX_PORT" => "")
    assert_equal 8080, config.port
    assert_raises(ConfigError) { Config.parse([], "SYNCBOX_DATA_DIR" => "") }
  end

  def test_data_dir_is_required
    error = assert_raises(ConfigError) { Config.parse(%w[--port 9000], {}) }
    assert_match(/--data-dir/, error.message)
  end

  def test_data_dir_flag_without_value
    assert_raises(ConfigError) { Config.parse(%w[--data-dir], {}) }
  end

  def test_invalid_ports_are_rejected
    ["0", "65536", "-1", "abc", "80x", "1.5", "0x50"].each do |port|
      error = assert_raises(ConfigError, "port #{port.inspect}") { Config.parse(["--data-dir", "/d", "--port", port], {}) }
      assert_match(/--port/, error.message)
    end
  end

  def test_invalid_port_from_environment_names_the_variable
    error = assert_raises(ConfigError) { Config.parse(%w[--data-dir /d], "SYNCBOX_PORT" => "nope") }
    assert_match(/SYNCBOX_PORT/, error.message)
  end

  def test_unknown_option_is_rejected
    assert_raises(ConfigError) { Config.parse(%w[--data-dir /d --verbose], {}) }
  end

  def test_unexpected_positional_argument_is_rejected
    assert_raises(ConfigError) { Config.parse(%w[--data-dir /d extra], {}) }
  end

  def test_prepare_data_dir_creates_missing_directory
    Dir.mktmpdir do |tmp|
      dir = File.join(tmp, "nested", "data")
      Config.new(data_dir: dir, port: 8080).prepare_data_dir!
      assert File.directory?(dir)
    end
  end

  def test_prepare_data_dir_rejects_regular_file
    Dir.mktmpdir do |tmp|
      file = File.join(tmp, "file")
      File.write(file, "x")
      assert_raises(ConfigError) { Config.new(data_dir: file, port: 8080).prepare_data_dir! }
    end
  end

  def test_prepare_data_dir_rejects_read_only_directory
    skip "root can write anywhere" if Process.uid.zero?

    Dir.mktmpdir do |tmp|
      File.chmod(0o555, tmp)
      assert_raises(ConfigError) { Config.new(data_dir: tmp, port: 8080).prepare_data_dir! }
    ensure
      File.chmod(0o755, tmp)
    end
  end
end
