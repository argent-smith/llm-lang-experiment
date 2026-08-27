package syncbox.server

import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer}

import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.util.concurrent.Executors

object Server:

  /** Starts an HTTP server bound to config.port with the routes implemented
    * so far. The returned server is already started; call .stop(0) to shut
    * it down.
    */
  def start(config: Config): HttpServer =
    val server = HttpServer.create(new InetSocketAddress(config.port), 0)
    server.createContext("/healthz", healthzHandler)
    server.setExecutor(Executors.newVirtualThreadPerTaskExecutor())
    server.start()
    server

  private val healthzHandler: HttpHandler = (exchange: HttpExchange) =>
    try
      if exchange.getRequestMethod == "GET" then
        val body = "ok".getBytes(StandardCharsets.UTF_8)
        exchange.getResponseHeaders.add("Content-Type", "text/plain; charset=utf-8")
        exchange.sendResponseHeaders(200, body.length)
        val os = exchange.getResponseBody
        try os.write(body)
        finally os.close()
      else
        exchange.getResponseHeaders.add("Allow", "GET")
        exchange.sendResponseHeaders(405, -1)
    finally
      exchange.close()
end Server
