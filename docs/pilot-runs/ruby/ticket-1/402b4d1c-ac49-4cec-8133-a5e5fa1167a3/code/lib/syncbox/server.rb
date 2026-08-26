require "sinatra/base"

module Syncbox
  class Server < Sinatra::Base
    set :data_dir, nil
    set :show_exceptions, false
    set :raise_errors, false

    get "/healthz" do
      status 200
      "ok"
    end
  end
end
