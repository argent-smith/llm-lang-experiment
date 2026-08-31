require "spec_helper"
require "syncbox/config"

RSpec.describe Syncbox::Config do
  describe ".parse" do
    it "raises when --data-dir is missing and no env var is set" do
      expect { described_class.parse([], {}) }.to raise_error(Syncbox::ConfigError, /--data-dir/)
    end

    it "parses --data-dir and --port from argv" do
      config = described_class.parse(["--data-dir", "/tmp/data", "--port", "9090"], {})

      expect(config.data_dir).to eq("/tmp/data")
      expect(config.port).to eq(9090)
    end

    it "defaults the port to 8080 when not given" do
      config = described_class.parse(["--data-dir", "/tmp/data"], {})

      expect(config.port).to eq(8080)
    end

    it "falls back to SYNCBOX_DATA_DIR and SYNCBOX_PORT env vars" do
      env = { "SYNCBOX_DATA_DIR" => "/tmp/env-data", "SYNCBOX_PORT" => "9999" }
      config = described_class.parse([], env)

      expect(config.data_dir).to eq("/tmp/env-data")
      expect(config.port).to eq(9999)
    end

    it "prefers explicit flags over env vars" do
      env = { "SYNCBOX_DATA_DIR" => "/tmp/env-data", "SYNCBOX_PORT" => "9999" }
      config = described_class.parse(["--data-dir", "/tmp/flag-data", "--port", "1234"], env)

      expect(config.data_dir).to eq("/tmp/flag-data")
      expect(config.port).to eq(1234)
    end

    it "mixes flags and env vars independently" do
      env = { "SYNCBOX_DATA_DIR" => "/tmp/env-data" }
      config = described_class.parse(["--port", "1234"], env)

      expect(config.data_dir).to eq("/tmp/env-data")
      expect(config.port).to eq(1234)
    end

    it "raises on a non-integer port" do
      expect do
        described_class.parse(["--data-dir", "/tmp/data", "--port", "not-a-number"], {})
      end.to raise_error(Syncbox::ConfigError, /--port/)
    end

    it "raises on an unknown argument" do
      expect do
        described_class.parse(["--bogus", "value"], {})
      end.to raise_error(Syncbox::ConfigError, /unknown argument/)
    end
  end
end
