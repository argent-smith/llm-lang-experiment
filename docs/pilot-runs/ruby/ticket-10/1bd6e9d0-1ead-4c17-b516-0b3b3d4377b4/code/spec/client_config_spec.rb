require_relative "../client/config"

RSpec.describe Syncbox::ClientConfig do
  it "raises when no command is given" do
    expect { described_class.parse([], {}) }.to raise_error(Syncbox::ClientConfig::Error)
  end

  it "raises for an unknown command" do
    expect { described_class.parse(["frobnicate", "dir", "--server", "http://x"], {}) }
      .to raise_error(Syncbox::ClientConfig::Error)
  end

  it "raises when <dir> is missing" do
    expect { described_class.parse(["push", "--server", "http://x"], {}) }
      .to raise_error(Syncbox::ClientConfig::Error)
  end

  it "raises when --server is missing and no env var is set" do
    expect { described_class.parse(["push", "dir"], {}) }.to raise_error(Syncbox::ClientConfig::Error)
  end

  it "parses command, dir and --server" do
    config = described_class.parse(["push", "some/dir", "--server", "http://localhost:8080"], {})

    expect(config.command).to eq("push")
    expect(config.dir).to eq("some/dir")
    expect(config.server).to eq("http://localhost:8080")
  end

  it "falls back to the SYNCBOX_SERVER env var" do
    config = described_class.parse(["push", "some/dir"], {"SYNCBOX_SERVER" => "http://example:9000"})

    expect(config.server).to eq("http://example:9000")
  end

  it "prefers the --server flag over the env var" do
    config = described_class.parse(
      ["push", "some/dir", "--server", "http://flag:1"],
      {"SYNCBOX_SERVER" => "http://env:2"}
    )

    expect(config.server).to eq("http://flag:1")
  end

  it "accepts pull/sync/status as valid commands" do
    %w[pull sync status].each do |cmd|
      config = described_class.parse([cmd, "dir", "--server", "http://x"], {})
      expect(config.command).to eq(cmd)
    end
  end
end
