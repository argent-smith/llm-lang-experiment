# frozen_string_literal: true

require "test_helper"
require "rack/lint"
require "rack/test"

class AppTest < Minitest::Test
  include Rack::Test::Methods

  def app
    config = Syncbox::Server::Config.new(data_dir: Dir.tmpdir, port: 8080)
    Rack::Lint.new(Syncbox::Server::Runner.build_app(config))
  end

  def test_healthz_returns_200
    get "/healthz"
    assert_equal 200, last_response.status
    assert_equal "ok\n", last_response.body
  end

  def test_healthz_head_returns_200_without_body
    head "/healthz"
    assert_equal 200, last_response.status
    assert_empty last_response.body
  end

  def test_healthz_rejects_other_methods
    %i[post put delete patch].each do |verb|
      send(verb, "/healthz")
      assert_equal 405, last_response.status, verb.to_s
      assert_equal "GET, HEAD", last_response.headers["allow"]
    end
  end

  def test_unknown_path_returns_404
    get "/nope"
    assert_equal 404, last_response.status
  end
end
