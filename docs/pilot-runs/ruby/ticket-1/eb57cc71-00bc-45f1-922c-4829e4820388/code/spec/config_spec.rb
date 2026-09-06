require_relative "../server/config"

RSpec.describe Syncbox::Config do
  it "raises when --data-dir is missing and no env var is set" do
    expect { described_class.parse([], {}) }.to raise_error(Syncbox::Config::Error)
  end

  it "parses --data-dir and defaults --port to 8080" do
    config = described_class.parse(["--data-dir", "/tmp/syncbox-data"], {})

    expect(config.data_dir).to eq("/tmp/syncbox-data")
    expect(config.port).to eq(8080)
  end

  it "parses an explicit --port" do
    config = described_class.parse(["--data-dir", "/tmp/syncbox-data", "--port", "9090"], {})

    expect(config.port).to eq(9090)
  end

  it "falls back to SYNCBOX_DATA_DIR / SYNCBOX_PORT env vars" do
    env = {"SYNCBOX_DATA_DIR" => "/tmp/from-env", "SYNCBOX_PORT" => "1234"}
    config = described_class.parse([], env)

    expect(config.data_dir).to eq("/tmp/from-env")
    expect(config.port).to eq(1234)
  end

  it "prefers CLI flags over env vars when both are given" do
    env = {"SYNCBOX_DATA_DIR" => "/tmp/from-env", "SYNCBOX_PORT" => "1234"}
    config = described_class.parse(["--data-dir", "/tmp/from-flag", "--port", "9999"], env)

    expect(config.data_dir).to eq("/tmp/from-flag")
    expect(config.port).to eq(9999)
  end
end
