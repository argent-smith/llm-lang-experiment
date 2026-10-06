# frozen_string_literal: true

require "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    config = Syncbox::Server::Config.new(data_dir: "/data")
    Syncbox::Server::App.new(config)
  end

  def test_healthz_returns_200
    get "/healthz"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.headers["content-type"]
    assert_equal({ "status" => "ok" }, JSON.parse(last_response.body))
  end

  def test_healthz_supports_head
    head "/healthz"
    assert_equal 200, last_response.status
  end

  def test_healthz_rejects_other_methods
    post "/healthz"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD", last_response.headers["allow"]
  end

  def test_unknown_path_returns_404
    get "/does-not-exist"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not found" }, JSON.parse(last_response.body))
  end

  def test_healthz_with_trailing_segment_is_not_healthz
    get "/healthz/extra"
    assert_equal 404, last_response.status
  end
end
