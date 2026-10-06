# frozen_string_literal: true

require "test_helper"

class ConfigTest < Minitest::Test
  def parse(argv, env = {})
    Syncbox::Config.parse(argv, env: env)
  end

  def test_flags_are_parsed
    config = parse(%w[--data-dir /srv/syncbox --port 9090])
    assert_equal "/srv/syncbox", config.data_dir
    assert_equal 9090, config.port
  end

  def test_flags_accept_equals_form
    config = parse(%w[--data-dir=/srv/syncbox --port=9090])
    assert_equal "/srv/syncbox", config.data_dir
    assert_equal 9090, config.port
  end

  def test_port_defaults_to_8080
    assert_equal 8080, parse(%w[--data-dir /srv/syncbox]).port
  end

  def test_env_variables_are_used_when_flags_absent
    config = parse([], "SYNCBOX_DATA_DIR" => "/from/env", "SYNCBOX_PORT" => "9001")
    assert_equal "/from/env", config.data_dir
    assert_equal 9001, config.port
  end

  def test_flags_take_precedence_over_env
    config = parse(%w[--data-dir /from/flag --port 7000],
                   "SYNCBOX_DATA_DIR" => "/from/env", "SYNCBOX_PORT" => "9001")
    assert_equal "/from/flag", config.data_dir
    assert_equal 7000, config.port
  end

  def test_empty_env_values_are_ignored
    error = assert_raises(Syncbox::Config::UsageError) { parse([], "SYNCBOX_DATA_DIR" => "  ") }
    assert_match(/--data-dir is required/, error.message)
    assert_equal 8080, parse(%w[--data-dir /d], "SYNCBOX_PORT" => "").port
  end

  def test_data_dir_is_required
    error = assert_raises(Syncbox::Config::UsageError) { parse([]) }
    assert_match(/--data-dir is required/, error.message)
  end

  def test_data_dir_is_expanded_to_absolute_path
    config = parse(%w[--data-dir relative/dir])
    assert_equal File.expand_path("relative/dir"), config.data_dir
  end

  def test_invalid_port_values_are_rejected
    ["abc", "0", "65536", "-1", "80.5", ""].each do |bad|
      assert_raises(Syncbox::Config::UsageError, "port #{bad.inspect} should be rejected") do
        parse(["--data-dir", "/d", "--port", bad])
      end
    end
    assert_raises(Syncbox::Config::UsageError) { parse(%w[--data-dir /d], "SYNCBOX_PORT" => "http") }
  end

  def test_unknown_option_is_a_usage_error
    assert_raises(Syncbox::Config::UsageError) { parse(%w[--data-dir /d --bogus]) }
  end

  def test_missing_option_argument_is_a_usage_error
    assert_raises(Syncbox::Config::UsageError) { parse(%w[--data-dir]) }
  end

  def test_help_is_reported_separately
    error = assert_raises(Syncbox::Config::HelpRequested) { parse(%w[--help]) }
    assert_match(/--data-dir/, error.message)
  end
end
