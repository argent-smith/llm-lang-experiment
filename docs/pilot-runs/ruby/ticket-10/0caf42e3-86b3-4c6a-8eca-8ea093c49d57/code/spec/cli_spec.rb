require "spec_helper"
require_relative "support/test_server"
require "syncbox/cli"
require "stringio"
require "tmpdir"

RSpec.describe Syncbox::CLI do
  describe ".parse" do
    it "raises when the command is missing" do
      expect { described_class.parse([], {}) }.to raise_error(Syncbox::CLIError, /missing command/)
    end

    it "raises on an unknown command" do
      expect { described_class.parse(["bogus", "dir"], {}) }.to raise_error(Syncbox::CLIError, /unknown command/)
    end

    it "raises when <dir> is missing" do
      expect do
        described_class.parse(["push"], { "SYNCBOX_SERVER" => "http://x" })
      end.to raise_error(Syncbox::CLIError, /missing <dir>/)
    end

    it "raises when --server is missing and no env var is set" do
      expect { described_class.parse(["push", "dir"], {}) }.to raise_error(Syncbox::CLIError, /--server/)
    end

    it "parses command, dir and --server from argv" do
      options = described_class.parse(["push", "mydir", "--server", "http://host:1234"], {})

      expect(options.command).to eq("push")
      expect(options.dir).to eq("mydir")
      expect(options.server).to eq("http://host:1234")
    end

    it "falls back to SYNCBOX_SERVER when --server is not given" do
      options = described_class.parse(["push", "mydir"], { "SYNCBOX_SERVER" => "http://env:9999" })

      expect(options.server).to eq("http://env:9999")
    end

    it "prefers an explicit --server flag over the env var" do
      options = described_class.parse(
        ["push", "mydir", "--server", "http://flag:1"],
        { "SYNCBOX_SERVER" => "http://env:2" }
      )

      expect(options.server).to eq("http://flag:1")
    end

    it "raises when --server is given without a value" do
      expect { described_class.parse(["push", "dir", "--server"], {}) }.to raise_error(Syncbox::CLIError, /--server/)
    end

    it "raises on a trailing unexpected positional argument" do
      expect do
        described_class.parse(["push", "dir", "extra", "--server", "http://x"], {})
      end.to raise_error(Syncbox::CLIError, /unexpected argument/)
    end
  end

  describe ".run" do
    def run(argv, env = {})
      stdout = StringIO.new
      stderr = StringIO.new
      status = described_class.run(argv, env, stdout: stdout, stderr: stderr)
      [status, stdout.string, stderr.string]
    end

    it "reports a parse error on stderr and exits non-zero instead of raising" do
      status, _out, err = run([])

      expect(status).not_to eq(0)
      expect(err).to include("syncbox:")
    end

    %w[sync].each do |command|
      it "reports '#{command}' as not implemented yet instead of crashing" do
        Dir.mktmpdir do |dir|
          status, _out, err = run([command, dir, "--server", "http://example.invalid"])

          expect(status).not_to eq(0)
          expect(err).to include("#{command} is not implemented yet")
        end
      end
    end

    %w[push pull status].each do |command|
      it "rejects a #{command} whose <dir> does not exist, without attempting the network" do
        status, _out, err = run([command, "/no/such/directory", "--server", "http://example.invalid"])

        expect(status).not_to eq(0)
        expect(err).to include("not a directory")
      end

      it "fails clearly for #{command} against an unreachable server instead of hanging or crashing" do
        Dir.mktmpdir do |dir|
          status, _out, err = run([command, dir, "--server", "http://127.0.0.1:1"])

          expect(status).not_to eq(0)
          expect(err).to include("syncbox:")
        end
      end
    end

    it "pushes local files to a real server end-to-end and prints a summary" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(local_dir, "hello.txt"), "hello")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["push", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).to include("uploaded hello.txt")
            expect(out).to include("push: 1 uploaded, 0 unchanged")
            expect(File.binread(File.join(data_dir, "hello.txt"))).to eq("hello")
          ensure
            server.stop
          end
        end
      end
    end

    it "pulls remote blobs to a real server end-to-end and prints a summary" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(data_dir, "hello.txt"), "hello")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["pull", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).to include("downloaded hello.txt")
            expect(out).to include("pull: 1 downloaded, 0 unchanged")
            expect(File.binread(File.join(local_dir, "hello.txt"))).to eq("hello")
          ensure
            server.stop
          end
        end
      end
    end

    it "reports a local-only file as to-upload, changing neither side" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(local_dir, "local-only.txt"), "local")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["status", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).to include("would upload   local-only.txt")
            expect(out).not_to include("would download")
            expect(out).to include("status: 1 to upload, 0 to download, 0 unchanged")
            expect(Dir.empty?(data_dir)).to be true
            expect(File.binread(File.join(local_dir, "local-only.txt"))).to eq("local")
          ensure
            server.stop
          end
        end
      end
    end

    it "reports a server-only file as to-download, changing neither side" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(data_dir, "server-only.txt"), "remote")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["status", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).to include("would download server-only.txt")
            expect(out).not_to include("would upload")
            expect(out).to include("status: 0 to upload, 1 to download, 0 unchanged")
            expect(Dir.empty?(local_dir)).to be true
            expect(File.binread(File.join(data_dir, "server-only.txt"))).to eq("remote")
          ensure
            server.stop
          end
        end
      end
    end

    it "reports a file that diverged in content as both to-upload and to-download, changing neither side" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(data_dir, "changed.txt"), "server version")
          File.write(File.join(local_dir, "changed.txt"), "local version")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["status", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).to include("would upload   changed.txt")
            expect(out).to include("would download changed.txt")
            expect(out).to include("status: 1 to upload, 1 to download, 0 unchanged")
            expect(File.binread(File.join(data_dir, "changed.txt"))).to eq("server version")
            expect(File.binread(File.join(local_dir, "changed.txt"))).to eq("local version")
          ensure
            server.stop
          end
        end
      end
    end

    it "reports no differences when local and server already match" do
      Dir.mktmpdir do |data_dir|
        Dir.mktmpdir do |local_dir|
          File.write(File.join(data_dir, "same.txt"), "same")
          File.write(File.join(local_dir, "same.txt"), "same")
          server = TestServer.start(data_dir)

          begin
            status, out, _err = run(["status", local_dir, "--server", server.url])

            expect(status).to eq(0)
            expect(out).not_to include("would upload")
            expect(out).not_to include("would download")
            expect(out).to include("status: 0 to upload, 0 to download, 1 unchanged")
          ensure
            server.stop
          end
        end
      end
    end
  end
end
