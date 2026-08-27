package syncbox.server

import munit.FunSuite

import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.nio.file.Files

class HealthzSpec extends FunSuite:

  private def withServer(testCode: Int => Unit): Unit =
    val dataDir = Files.createTempDirectory("syncbox-test")
    // Port 0 asks the OS for a free ephemeral port, so tests never collide.
    val server = Server.start(Config(dataDir, 0))
    try testCode(server.getAddress.getPort)
    finally server.stop(0)

  private val client = HttpClient.newHttpClient()

  test("GET /healthz returns 200") {
    withServer { port =>
      val request = HttpRequest.newBuilder(URI.create(s"http://127.0.0.1:$port/healthz")).GET().build()
      val response = client.send(request, HttpResponse.BodyHandlers.ofString())
      assertEquals(response.statusCode(), 200)
    }
  }

  test("POST /healthz returns 405") {
    withServer { port =>
      val request = HttpRequest
        .newBuilder(URI.create(s"http://127.0.0.1:$port/healthz"))
        .POST(HttpRequest.BodyPublishers.noBody())
        .build()
      val response = client.send(request, HttpResponse.BodyHandlers.ofString())
      assertEquals(response.statusCode(), 405)
    }
  }

  test("GET /unknown-path returns a non-2xx status") {
    withServer { port =>
      val request = HttpRequest.newBuilder(URI.create(s"http://127.0.0.1:$port/unknown-path")).GET().build()
      val response = client.send(request, HttpResponse.BodyHandlers.ofString())
      assert(response.statusCode() >= 400, s"expected an error status, got ${response.statusCode()}")
    }
  }
end HealthzSpec
