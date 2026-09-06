require "sinatra/base"

module Syncbox
  class App < Sinatra::Base
    set :data_dir, nil
    # Sinatra defaults to the "development" environment (no RACK_ENV set),
    # which restricts the Host header to localhost/.test/IP addresses;
    # this server is addressed by arbitrary hostnames (docker service names,
    # rack-test's default Host header, etc.), so disable that restriction.
    set :host_authorization, {}

    get "/healthz" do
      status 200
      ""
    end
  end
end
