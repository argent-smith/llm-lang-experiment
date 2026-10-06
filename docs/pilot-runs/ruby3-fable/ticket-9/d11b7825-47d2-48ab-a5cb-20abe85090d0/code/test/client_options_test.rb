# frozen_string_literal: true

require "test_helper"

# Разбор аргументов клиента: syncbox <command> <dir> --server <url>.
class ClientOptionsTest < Minitest::Test
  Options = Syncbox::Client::Options
  UsageError = Syncbox::Client::UsageError

  def parse(argv, env = {})
    Options.parse(argv, env: env)
  end

  def test_parses_command_dir_and_server_flag
    options = parse(%w[push /sync --server http://127.0.0.1:8080])
    assert_equal "push", options.command
    assert_equal "/sync", options.dir
    assert_kind_of URI::HTTP, options.server
    assert_equal "http://127.0.0.1:8080", options.server.to_s
    assert_equal "127.0.0.1", options.server.host
    assert_equal 8080, options.server.port
  end

  def test_flag_may_use_equals_form_and_come_first
    options = parse(%w[--server=http://localhost:9000 pull ./dir])
    assert_equal "pull", options.command
    assert_equal "./dir", options.dir
    assert_equal "http://localhost:9000", options.server.to_s
  end

  def test_all_four_commands_are_accepted
    Syncbox::Client::COMMANDS.each do |command|
      assert_equal command, parse([command, "/d", "--server", "http://h"]).command
    end
  end

  def test_server_falls_back_to_environment_variable
    options = parse(%w[status /d], "SYNCBOX_SERVER" => "http://env.example:8080")
    assert_equal "http://env.example:8080", options.server.to_s
  end

  def test_flag_takes_precedence_over_environment
    options = parse(%w[sync /d --server http://flag:1], "SYNCBOX_SERVER" => "http://env:2")
    assert_equal "http://flag:1", options.server.to_s
  end

  def test_blank_environment_value_is_ignored
    error = assert_raises(UsageError) { parse(%w[push /d], "SYNCBOX_SERVER" => "   ") }
    assert_match(/--server is required \(or set SYNCBOX_SERVER\)/, error.message)
  end

  def test_server_is_required
    error = assert_raises(UsageError) { parse(%w[push /d]) }
    assert_match(/--server is required/, error.message)
  end

  def test_server_flag_without_value_is_rejected
    error = assert_raises(UsageError) { parse(%w[push /d --server]) }
    assert_match(/missing argument/, error.message)
    error = assert_raises(UsageError) { parse(["push", "/d", "--server", ""]) }
    assert_match(/--server value must not be empty/, error.message)
  end

  def test_invalid_server_urls_are_rejected
    ["127.0.0.1:8080", "localhost:8080", "ftp://host/x", "http://", "http:///path", "not a url", "http://h?x=1", "http://h#frag"].each do |bad|
      error = assert_raises(UsageError, "#{bad.inspect} should be rejected") { parse(["push", "/d", "--server", bad]) }
      assert_match(/invalid --server value/, error.message)
    end
  end

  def test_server_trailing_slashes_are_stripped
    assert_equal "http://h:1", parse(%w[push /d --server http://h:1/]).server.to_s
    assert_equal "http://h:1/prefix", parse(%w[push /d --server http://h:1/prefix//]).server.to_s
  end

  def test_https_is_accepted
    options = parse(%w[push /d --server https://secure.example])
    assert_equal "https", options.server.scheme
    assert_equal 443, options.server.port
  end

  def test_command_is_required
    error = assert_raises(UsageError) { parse([]) }
    assert_match(/command is required/, error.message)
    error = assert_raises(UsageError) { parse(%w[--server http://h]) }
    assert_match(/command is required/, error.message)
  end

  def test_unknown_command_is_rejected
    error = assert_raises(UsageError) { parse(%w[upload /d --server http://h]) }
    assert_match(/unknown command "upload"/, error.message)
  end

  def test_dir_is_required
    error = assert_raises(UsageError) { parse(%w[push --server http://h]) }
    assert_match(/push requires <dir>/, error.message)
  end

  def test_extra_positional_arguments_are_rejected
    error = assert_raises(UsageError) { parse(%w[push /d /e --server http://h]) }
    assert_match(/unexpected arguments: \/e/, error.message)
  end

  def test_unknown_flags_are_rejected
    error = assert_raises(UsageError) { parse(%w[push /d --server http://h --bogus]) }
    assert_match(/invalid option: --bogus/, error.message)
  end

  def test_help_and_version
    error = assert_raises(Syncbox::Client::HelpRequested) { parse(%w[--help]) }
    assert_match(/Usage: syncbox <push\|pull\|sync\|status> <dir> --server <url>/, error.message)
    error = assert_raises(Syncbox::Client::HelpRequested) { parse(%w[push /d -h]) }
    assert_match(/Usage: syncbox/, error.message)
    error = assert_raises(Syncbox::Client::HelpRequested) { parse(%w[--version]) }
    assert_equal "syncbox #{Syncbox::VERSION}", error.message
  end

  def test_usage_mentions_commands_and_server_flag
    usage = Options.usage
    assert_match(/Usage: syncbox/, usage)
    %w[push pull sync status --server SYNCBOX_SERVER].each { |word| assert_includes usage, word }
  end
end
