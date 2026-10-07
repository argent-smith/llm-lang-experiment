# frozen_string_literal: true

require "test_helper"

class ClientConfigTest < Minitest::Test
  Config = Syncbox::Client::Config

  def test_command_directory_and_server
    config = Config.parse(["push", "/srv/dir", "--server", "http://127.0.0.1:8080"], {})

    assert_equal "push", config.command
    assert_equal "/srv/dir", config.dir
    assert_equal "http://127.0.0.1:8080", config.server.to_s
  end

  def test_all_commands_are_accepted
    %w[push pull status sync].each do |command|
      assert_equal command, Config.parse([command, "d", "--server", "http://h"], {}).command
    end
  end

  def test_flag_may_come_first_or_use_an_equals_sign
    config = Config.parse(["--server=http://h:9000", "push", "d"], {})

    assert_equal "http://h:9000", config.server.to_s
    assert_equal "push", config.command
  end

  def test_server_from_environment
    assert_equal "http://env:1", Config.parse(%w[push d], { "SYNCBOX_SERVER" => "http://env:1" }).server.to_s
  end

  def test_flag_takes_precedence_over_environment
    config = Config.parse(["push", "d", "--server", "http://flag"], { "SYNCBOX_SERVER" => "http://env" })

    assert_equal "http://flag", config.server.to_s
  end

  def test_server_is_required
    [[{}], [{ "SYNCBOX_SERVER" => "" }]].each do |(env)|
      error = assert_raises(Config::Error) { Config.parse(%w[push d], env) }
      assert_match(/--server/, error.message)
      assert_match(/SYNCBOX_SERVER/, error.message)
    end
  end

  def test_relative_directory_is_expanded
    Dir.chdir(Dir.tmpdir) do
      assert_equal File.join(Dir.pwd, "dir"), Config.parse(["push", "dir", "--server", "http://h"], {}).dir
    end
  end

  def test_https_and_base_paths_are_accepted
    ["https://h", "http://h/", "http://h:8080/syncbox/", "http://[::1]:8080"].each do |url|
      assert_equal url, Config.parse(["push", "d", "--server", url], {}).server.to_s
    end
  end

  def test_invalid_server_urls_are_rejected
    ["localhost:8080", "127.0.0.1", "ftp://h", "http://", "http:///x", "http://h/?q=1", "http://h/#f",
     "http://h:port", "http://h h", "file:///tmp"].each do |url|
      error = assert_raises(Config::Error, url) { Config.parse(["push", "d", "--server", url], {}) }
      assert_match(/invalid server URL/, error.message, url)
    end
  end

  def test_invalid_command_lines_are_rejected
    server = "--server=http://h"
    [
      [server], ["push", server], ["frobnicate", "d", server], ["PUSH", "d", server], ["push", "", server],
      ["push", "d", "extra", server], ["push", "d", "--verbose", server], %w[push d --serv http://h],
      %w[push d --server]
    ].each do |argv|
      assert_raises(Config::Error, argv.inspect) { Config.parse(argv, {}) }
    end
  end

  def test_help
    assert_raises(Config::HelpRequested) { Config.parse(["--help"], {}) }
    assert_raises(Config::HelpRequested) { Config.parse(%w[push d -h], {}) }
  end
end
