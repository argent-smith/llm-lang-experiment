# frozen_string_literal: true

require "test_helper"
require "stringio"

# Юнит-тесты CLI без запуска реального сервера: подменяем Syncbox::Server.
class CLITest < Minitest::Test
  FakeServer = Struct.new(:config, :out, :err) do
    def initialize(config, out:, err:)
      super(config, out, err)
    end

    def run
      self.class.last = self
    end

    class << self
      attr_accessor :last
    end
  end

  def setup
    @out = StringIO.new
    @err = StringIO.new
    FakeServer.last = nil
    Syncbox.send(:remove_const, :Server)
    Syncbox.const_set(:Server, FakeServer)
  end

  def teardown
    Syncbox.send(:remove_const, :Server)
    load File.expand_path("../lib/syncbox/server.rb", __dir__)
  end

  def run_cli(argv, env = {})
    Syncbox::CLI.run(argv, env: env, out: @out, err: @err)
  end

  def test_runs_server_with_parsed_config_and_creates_data_dir
    Dir.mktmpdir do |tmp|
      data_dir = File.join(tmp, "nested", "data")
      status = run_cli(["--data-dir", data_dir, "--port", "9999"])

      assert_equal 0, status
      assert File.directory?(data_dir), "data dir should be created"
      assert_equal data_dir, FakeServer.last.config.data_dir
      assert_equal 9999, FakeServer.last.config.port
    end
  end

  def test_missing_data_dir_prints_usage_and_exits_2
    status = run_cli([])
    assert_equal 2, status
    assert_nil FakeServer.last
    assert_match(/--data-dir is required/, @err.string)
    assert_match(/Usage: syncbox-server/, @err.string)
  end

  def test_invalid_port_exits_2
    status = run_cli(%w[--data-dir /tmp --port nope])
    assert_equal 2, status
    assert_nil FakeServer.last
    assert_match(/invalid --port value/, @err.string)
  end

  def test_help_exits_0
    status = run_cli(%w[--help])
    assert_equal 0, status
    assert_match(/Usage: syncbox-server/, @out.string)
    assert_nil FakeServer.last
  end

  def test_unwritable_data_dir_exits_1
    skip "root ignores file permissions" if Process.uid.zero?
    Dir.mktmpdir do |tmp|
      File.chmod(0o500, tmp)
      status = run_cli(["--data-dir", File.join(tmp, "data")])
      assert_equal 1, status
      assert_nil FakeServer.last
      assert_match(/syncbox-server: /, @err.string)
    ensure
      File.chmod(0o700, tmp)
    end
  end
end
