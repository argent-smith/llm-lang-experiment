require "spec_helper"
require "syncbox/server"

RSpec.describe Syncbox::Server do
  include Rack::Test::Methods

  def app
    Syncbox::Server
  end

  describe "GET /healthz" do
    it "returns 200" do
      get "/healthz", {}, { "HTTP_HOST" => "localhost" }

      expect(last_response.status).to eq(200)
    end
  end
end
