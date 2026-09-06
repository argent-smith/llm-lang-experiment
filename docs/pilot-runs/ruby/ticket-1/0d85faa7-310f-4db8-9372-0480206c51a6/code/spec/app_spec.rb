require "rack/test"
require_relative "../server/app"

RSpec.describe Syncbox::App do
  include Rack::Test::Methods

  def app
    Syncbox::App
  end

  describe "GET /healthz" do
    it "responds with 200" do
      get "/healthz"

      expect(last_response.status).to eq(200)
    end
  end
end
