package syncbox.server

import munit.FunSuite

import java.net.URI
import java.net.http.{HttpClient, HttpRequest, HttpResponse}
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.security.MessageDigest

class BlobsSpec extends FunSuite:

  private def withServer(testCode: Int => Unit): Unit =
    val dataDir = Files.createTempDirectory("syncbox-test")
    val server = Server.start(Config(dataDir, 0))
    try testCode(server.getAddress.getPort)
    finally server.stop(0)

  private val client = HttpClient.newHttpClient()

  private def put(port: Int, key: String, content: Array[Byte]): HttpResponse[String] =
    val request = HttpRequest
      .newBuilder(URI.create(s"http://127.0.0.1:$port/blobs/$key"))
      .PUT(HttpRequest.BodyPublishers.ofByteArray(content))
      .build()
    client.send(request, HttpResponse.BodyHandlers.ofString())

  private def get(port: Int, key: String): HttpResponse[Array[Byte]] =
    val request = HttpRequest.newBuilder(URI.create(s"http://127.0.0.1:$port/blobs/$key")).GET().build()
    client.send(request, HttpResponse.BodyHandlers.ofByteArray())

  private def sha256Hex(bytes: Array[Byte]): String =
    MessageDigest.getInstance("SHA-256").digest(bytes).map(b => f"${b & 0xff}%02x").mkString

  private def jsonField(json: String, name: String): String =
    val pattern = raw""""$name"\s*:\s*"?([^",}]+)"?""".r
    pattern.findFirstMatchIn(json).map(_.group(1)).getOrElse(fail(s"field $name not found in $json"))

  test("PUT then GET round-trips the exact bytes") {
    withServer { port =>
      val content = "hello syncbox".getBytes(StandardCharsets.UTF_8)
      val putResponse = put(port, "greeting.txt", content)
      assertEquals(putResponse.statusCode(), 201)

      val getResponse = get(port, "greeting.txt")
      assertEquals(getResponse.statusCode(), 200)
      assertEquals(getResponse.body().toSeq, content.toSeq)
    }
  }

  test("PUT response contains key, sha256 and size") {
    withServer { port =>
      val content = "some content for hashing".getBytes(StandardCharsets.UTF_8)
      val response = put(port, "file.bin", content)
      assertEquals(response.statusCode(), 201)

      val json = response.body()
      assertEquals(jsonField(json, "key"), "file.bin")
      assertEquals(jsonField(json, "sha256"), sha256Hex(content))
      assertEquals(jsonField(json, "size"), content.length.toString)
    }
  }

  test("PUT creates nested directories for keys with slashes") {
    withServer { port =>
      val content = "nested readme".getBytes(StandardCharsets.UTF_8)
      val putResponse = put(port, "docs/readme.txt", content)
      assertEquals(putResponse.statusCode(), 201)
      assertEquals(jsonField(putResponse.body(), "key"), "docs/readme.txt")

      val getResponse = get(port, "docs/readme.txt")
      assertEquals(getResponse.statusCode(), 200)
      assertEquals(getResponse.body().toSeq, content.toSeq)
    }
  }

  test("GET on a missing key returns 404") {
    withServer { port =>
      val response = get(port, "does/not/exist.txt")
      assertEquals(response.statusCode(), 404)
    }
  }

  test("PUT overwrites an existing key") {
    withServer { port =>
      put(port, "overwrite.txt", "first".getBytes(StandardCharsets.UTF_8))
      val secondContent = "second and longer".getBytes(StandardCharsets.UTF_8)
      put(port, "overwrite.txt", secondContent)

      val getResponse = get(port, "overwrite.txt")
      assertEquals(getResponse.statusCode(), 200)
      assertEquals(getResponse.body().toSeq, secondContent.toSeq)
    }
  }

  test("PUT with empty body stores an empty blob") {
    withServer { port =>
      val putResponse = put(port, "empty.txt", Array.emptyByteArray)
      assertEquals(putResponse.statusCode(), 201)
      assertEquals(jsonField(putResponse.body(), "size"), "0")

      val getResponse = get(port, "empty.txt")
      assertEquals(getResponse.statusCode(), 200)
      assertEquals(getResponse.body().length, 0)
    }
  }
end BlobsSpec
