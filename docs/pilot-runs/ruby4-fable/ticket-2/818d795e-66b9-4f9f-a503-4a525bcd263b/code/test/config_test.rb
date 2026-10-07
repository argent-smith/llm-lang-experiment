# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  Config = Syncbox::Server::Config

  def parse(argv, env = {})
    Config.parse(argv, env: env)
  end

  def test_flags_are_parsed
    config = parse(%w[--data-dir /tmp/store --port 9090])
    assert_equal "/tmp/store", config.data_dir
    assert_equal 9090, config.port
  end

  def test_equals_form_of_flags
    config = parse(%w[--data-dir=/tmp/store --port=9091])
    assert_equal "/tmp/store", config.data_dir
    assert_equal 9091, config.port
  end

  def test_port_defaults_to_8080
    assert_equal 8080, parse(%w[--data-dir /tmp/store]).port
  end

  def test_environment_variables_are_used_as_fallback
    config = parse([], { "SYNCBOX_DATA_DIR" => "/var/store", "SYNCBOX_PORT" => "7000" })
    assert_equal "/var/store", config.data_dir
    assert_equal 7000, config.port
  end

  def test_flags_take_precedence_over_environment
    env = { "SYNCBOX_DATA_DIR" => "/var/env", "SYNCBOX_PORT" => "7000" }
    config = parse(%w[--data-dir /var/flag --port 7001], env)
    assert_equal "/var/flag", config.data_dir
    assert_equal 7001, config.port
  end

  def test_blank_environment_values_are_ignored
    env = { "SYNCBOX_DATA_DIR" => "   ", "SYNCBOX_PORT" => "" }
    error = assert_raises(Config::Error) { parse([], env) }
    assert_match(/--data-dir is required/, error.message)
  end

  def test_relative_data_dir_is_expanded
    config = parse(%w[--data-dir store])
    assert_equal File.expand_path("store"), config.data_dir
  end

  def test_data_dir_is_required
    error = assert_raises(Config::Error) { parse(%w[--port 8080]) }
    assert_match(/--data-dir is required/, error.message)
    assert_match(/SYNCBOX_DATA_DIR/, error.message)
  end

  def test_data_dir_flag_without_value_is_an_error
    assert_raises(Config::Error) { parse(%w[--data-dir]) }
  end

  def test_non_numeric_port_is_rejected
    error = assert_raises(Config::Error) { parse(%w[--data-dir /tmp --port http]) }
    assert_match(/invalid port/, error.message)
  end

  def test_out_of_range_ports_are_rejected
    assert_raises(Config::Error) { parse(%w[--data-dir /tmp --port 0]) }
    assert_raises(Config::Error) { parse(%w[--data-dir /tmp --port 65536]) }
    assert_raises(Config::Error) { parse(%w[--data-dir /tmp --port -1]) }
  end

  def test_invalid_port_from_environment_is_rejected
    assert_raises(Config::Error) { parse([], { "SYNCBOX_DATA_DIR" => "/tmp", "SYNCBOX_PORT" => "nope" }) }
  end

  def test_unknown_flag_is_rejected
    error = assert_raises(Config::Error) { parse(%w[--data-dir /tmp --verbose]) }
    assert_match(/--verbose/, error.message)
  end

  def test_help_raises_help_requested_with_usage
    error = assert_raises(Config::HelpRequested) { parse(%w[--help]) }
    assert_match(/--data-dir/, error.message)
    assert_match(/--port/, error.message)
  end

  def test_host_defaults_to_all_interfaces
    assert_equal "0.0.0.0", parse(%w[--data-dir /tmp]).host
  end
end
