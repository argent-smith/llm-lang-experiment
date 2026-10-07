# frozen_string_literal: true

require "test_helper"
require "stringio"

# Command line of the syncbox client: <command> <dir> --server <url>.
class ClientOptionsTest < Minitest::Test
  Options = Syncbox::Client::Options
  UsageError = Syncbox::Client::UsageError

  def test_parses_command_dir_and_server
    options = Options.parse(%w[push some/dir --server http://127.0.0.1:8080], {})
    assert_equal "push", options.command
    assert_equal "some/dir", options.dir
    assert_equal URI("http://127.0.0.1:8080"), options.server
  end

  def test_accepts_every_command_and_flag_in_any_position
    %w[push pull sync status].each do |command|
      assert_equal command, Options.parse(["--server", "http://h", command, "d"], {}).command
      assert_equal "d", Options.parse([command, "--server=http://h", "d"], {}).dir
    end
  end

  def test_server_falls_back_to_environment_and_flag_wins
    assert_equal URI("http://env:1"), Options.parse(%w[push d], { "SYNCBOX_SERVER" => "http://env:1" }).server
    assert_equal URI("https://flag"),
                 Options.parse(%w[push d --server https://flag], { "SYNCBOX_SERVER" => "http://env:1" }).server
  end

  def test_server_is_required
    [{}, { "SYNCBOX_SERVER" => "" }].each do |env|
      error = assert_raises(UsageError) { Options.parse(%w[push d], env) }
      assert_match(/--server.*SYNCBOX_SERVER.*required/, error.message)
    end
  end

  def test_rejects_servers_that_are_not_http_urls
    ["127.0.0.1:8080", "ftp://host", "http://", "http://h/?q=1", "http://h/#x", "http://bad host", "/path"].each do |url|
      error = assert_raises(UsageError, url) { Options.parse(["push", "d", "--server", url], {}) }
      assert_match(/http/, error.message)
    end
  end

  def test_rejects_malformed_command_lines
    [[], %w[--server http://h], %w[push --server http://h], %w[upload d --server http://h],
     %w[push d extra --server http://h], %w[push d --server], %w[push d --bogus --server http://h],
     ["push", "", "--server", "http://h"]].each do |argv|
      assert_raises(UsageError, argv.inspect) { Options.parse(argv, {}) }
    end
  end

  def test_help_prints_usage
    out = StringIO.new
    assert_equal 0, Syncbox::Client::CLI.run(%w[--help], env: {}, out: out, err: StringIO.new)
    assert_match(/Usage: syncbox <push\|pull\|sync\|status> <dir> --server <url>/, out.string)
  end

  def test_usage_errors_exit_with_2_and_explain
    err = StringIO.new
    assert_equal 2, Syncbox::Client::CLI.run(%w[push d], env: {}, out: StringIO.new, err: err)
    assert_match(/--server/, err.string)
    assert_match(/Usage:/, err.string)
  end

  def test_sync_says_it_is_not_implemented
    Dir.mktmpdir do |dir|
      out = StringIO.new
      err = StringIO.new
      status = Syncbox::Client::CLI.run(["sync", dir, "--server", "http://127.0.0.1:1"], env: {}, out: out, err: err)
      assert_equal 1, status
      assert_equal "syncbox: 'sync' is not implemented yet (available: push, pull, status)\n", err.string
      assert_empty out.string
      assert_empty Dir.children(dir)
    end
  end
end
