let router = Dream.router [ Dream.get "/healthz" (fun _ -> Dream.respond "ok") ]
