# frozen_string_literal: true

require "test_helper"
require "rack/mock"

class AppTest < Minitest::Test
  def setup
    config = Syncbox::Server::Config.new(data_dir: Dir.tmpdir, port: "8080")
    @app = Rack::MockRequest.new(Syncbox::Server::App.new(config))
  end

  def test_healthz
    response = @app.get("/healthz")

    assert_equal 200, response.status
  end

  def test_healthz_head
    assert_equal 200, @app.head("/healthz").status
  end

  def test_healthz_rejects_other_methods
    %i[post put delete patch].each do |method|
      response = @app.request(method.to_s.upcase, "/healthz")

      assert_equal 405, response.status, method
      assert_equal "GET, HEAD", response.headers["allow"]
    end
  end

  def test_unknown_paths_are_not_found
    ["/", "/healthz/", "/healthzz", "/nope"].each do |path|
      assert_equal 404, @app.get(path).status, path
    end
  end
end
