# frozen_string_literal: true

require "test_helper"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= Syncbox::App.new(Syncbox::Config.new(data_dir: Dir.tmpdir))
  end

  def test_healthz_returns_200
    get "/healthz"
    assert_equal 200, last_response.status
    assert_match %r{\Aapplication/json}, last_response.content_type
    assert_equal({ "status" => "ok" }, JSON.parse(last_response.body))
  end

  def test_head_healthz_returns_200_without_body
    head "/healthz"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_unknown_path_returns_404_json
    get "/nope"
    assert_equal 404, last_response.status
    assert_equal({ "error" => "not_found" }, JSON.parse(last_response.body))
  end

  def test_wrong_method_on_known_path_returns_405
    post "/healthz"
    assert_equal 405, last_response.status
    assert_equal "GET", last_response.headers["allow"]
  end
end
