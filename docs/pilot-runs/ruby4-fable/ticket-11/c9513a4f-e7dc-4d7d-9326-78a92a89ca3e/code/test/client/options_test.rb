# frozen_string_literal: true

require "test_helper"

class ClientOptionsTest < Minitest::Test
  Options = Syncbox::Client::Options

  def parse(argv, env = {})
    Options.parse(argv, env: env)
  end

  def test_command_dir_and_server_are_parsed
    options = parse(%w[push ./photos --server http://127.0.0.1:8080])
    assert_equal "push", options.command
    assert_equal "./photos", options.dir
    assert_equal "http://127.0.0.1:8080", options.server.to_s
    assert_equal "", options.server.path
  end

  def test_flags_may_come_anywhere
    options = parse(%w[--server http://h:1 push dir])
    assert_equal %w[push dir http://h:1], [options.command, options.dir, options.server.to_s]
    options = parse(%w[push --server=http://h:1 dir])
    assert_equal %w[push dir http://h:1], [options.command, options.dir, options.server.to_s]
  end

  def test_all_four_commands_are_accepted
    %w[push pull sync status].each do |command|
      assert_equal command, parse([command, "d", "--server", "http://h"]).command
    end
  end

  def test_environment_variable_is_used_as_fallback
    options = parse(%w[push dir], { "SYNCBOX_SERVER" => "http://env-host:9000" })
    assert_equal "http://env-host:9000", options.server.to_s
  end

  def test_flag_takes_precedence_over_environment
    options = parse(%w[push dir --server http://flag-host], { "SYNCBOX_SERVER" => "http://env-host" })
    assert_equal "http://flag-host", options.server.to_s
  end

  def test_blank_environment_value_is_ignored
    error = assert_raises(Options::Error) { parse(%w[push dir], { "SYNCBOX_SERVER" => "   " }) }
    assert_match(/--server is required/, error.message)
    assert_match(/SYNCBOX_SERVER/, error.message)
  end

  def test_server_is_required
    error = assert_raises(Options::Error) { parse(%w[push dir]) }
    assert_match(/--server is required \(or set SYNCBOX_SERVER\)/, error.message)
  end

  def test_server_flag_without_value_is_an_error
    assert_raises(Options::Error) { parse(%w[push dir --server]) }
  end

  def test_trailing_slashes_and_prefix_paths_are_normalised
    assert_equal "", parse(%w[push d --server http://h:1/]).server.path
    assert_equal "", parse(%w[push d --server http://h:1///]).server.path
    assert_equal "/prefix", parse(%w[push d --server http://h:1/prefix/]).server.path
    assert_equal "https", parse(%w[push d --server https://h/]).server.scheme
    assert_equal 443, parse(%w[push d --server https://h/]).server.port
  end

  def test_surrounding_whitespace_in_url_is_tolerated
    assert_equal "http://h:1", parse(["push", "d", "--server", " http://h:1 "]).server.to_s
  end

  def test_invalid_server_urls_are_rejected
    ["127.0.0.1:8080", "ftp://h", "http://", "http:///path", "not a url", "http://h/?q=1", "http://h/#frag", ""].each do |url|
      error = assert_raises(Options::Error, url) { parse(["push", "d", "--server", url]) }
      assert_match(/invalid server URL|--server is required/, error.message, url)
    end
  end

  def test_missing_command_is_an_error
    error = assert_raises(Options::Error) { parse(%w[--server http://h]) }
    assert_match(/missing command/, error.message)
  end

  def test_unknown_command_is_an_error
    error = assert_raises(Options::Error) { parse(%w[fetch dir --server http://h]) }
    assert_match(/unknown command "fetch"/, error.message)
    assert_match(/push, pull, sync, status/, error.message)
  end

  def test_missing_dir_is_an_error
    error = assert_raises(Options::Error) { parse(%w[push --server http://h]) }
    assert_match(/missing <dir>/, error.message)
  end

  def test_extra_positional_arguments_are_rejected
    error = assert_raises(Options::Error) { parse(%w[push dir extra --server http://h]) }
    assert_match(/unexpected argument\(s\): extra/, error.message)
  end

  def test_unknown_flag_is_rejected
    error = assert_raises(Options::Error) { parse(%w[push dir --server http://h --verbose]) }
    assert_match(/--verbose/, error.message)
  end

  def test_help_is_requested_with_usage_text
    error = assert_raises(Options::HelpRequested) { parse(%w[--help]) }
    assert_match(/Usage: syncbox <push\|pull\|sync\|status> <dir> --server <url>/, error.message)
    assert_raises(Options::HelpRequested) { parse(%w[push dir -h]) }
    assert_match(/SYNCBOX_SERVER/, Options.usage)
  end
end
