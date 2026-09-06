require "sinatra/base"

module Syncbox
  class App < Sinatra::Base
    set :data_dir, nil

    get "/healthz" do
      status 200
      ""
    end
  end
end
