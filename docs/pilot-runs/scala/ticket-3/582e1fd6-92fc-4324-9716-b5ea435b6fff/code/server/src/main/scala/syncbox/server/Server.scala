package syncbox.server

import com.sun.net.httpserver.{HttpExchange, HttpHandler, HttpServer}

import java.io.OutputStream
import java.net.InetSocketAddress
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Path, StandardOpenOption}
import java.security.{DigestInputStream, DigestOutputStream, MessageDigest}
import java.util.concurrent.Executors
import scala.jdk.CollectionConverters.*

object Server:

  /** Starts an HTTP server bound to config.port with the routes implemented
    * so far. The returned server is already started; call .stop(0) to shut
    * it down.
    */
  def start(config: Config): HttpServer =
    val server = HttpServer.create(new InetSocketAddress(config.port), 0)
    server.createContext("/healthz", healthzHandler)
    server.createContext("/blobs", listBlobsHandler(config.dataDir))
    server.createContext("/blobs/", blobsHandler(config.dataDir))
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

  /** Handles GET/PUT under /blobs/{key}, where key is everything after the
    * "/blobs/" prefix (already percent-decoded by URI.getPath, and may
    * contain further "/" for nested directories).
    */
  private def blobsHandler(dataDir: Path): HttpHandler = (exchange: HttpExchange) =>
    try
      val key = exchange.getRequestURI.getPath.stripPrefix("/blobs/")
      exchange.getRequestMethod match
        case "PUT" => putBlob(exchange, dataDir, key)
        case "GET" => getBlob(exchange, dataDir, key)
        case _ =>
          exchange.getResponseHeaders.add("Allow", "GET, PUT")
          exchange.sendResponseHeaders(405, -1)
    catch
      case _: Exception =>
        exchange.sendResponseHeaders(500, -1)
    finally
      exchange.close()

  private def putBlob(exchange: HttpExchange, dataDir: Path, key: String): Unit =
    val target = dataDir.resolve(key)
    Files.createDirectories(target.getParent)
    val digest = MessageDigest.getInstance("SHA-256")
    val size =
      val out = Files.newOutputStream(
        target,
        StandardOpenOption.CREATE,
        StandardOpenOption.WRITE,
        StandardOpenOption.TRUNCATE_EXISTING
      )
      try exchange.getRequestBody.transferTo(new DigestOutputStream(out, digest))
      finally out.close()
    val sha256 = toHex(digest.digest())
    val json = s"""{"key":${jsonString(key)},"sha256":"$sha256","size":$size}"""
    val body = json.getBytes(StandardCharsets.UTF_8)
    exchange.getResponseHeaders.add("Content-Type", "application/json")
    exchange.sendResponseHeaders(201, body.length)
    val os = exchange.getResponseBody
    try os.write(body)
    finally os.close()

  private def getBlob(exchange: HttpExchange, dataDir: Path, key: String): Unit =
    val target = dataDir.resolve(key)
    if Files.isRegularFile(target) then
      exchange.getResponseHeaders.add("Content-Type", "application/octet-stream")
      exchange.sendResponseHeaders(200, Files.size(target))
      val os = exchange.getResponseBody
      try Files.copy(target, os)
      finally os.close()
    else
      exchange.sendResponseHeaders(404, -1)

  /** Handles GET /blobs: lists every regular file under dataDir, recursively,
    * as a JSON array of {key, size, sha256, modified_at}, sorted by key.
    */
  private def listBlobsHandler(dataDir: Path): HttpHandler = (exchange: HttpExchange) =>
    try
      if exchange.getRequestMethod == "GET" then
        val entries = listBlobs(dataDir).sortBy(_.key)
        val json = entries.map(_.toJson).mkString("[", ",", "]")
        val body = json.getBytes(StandardCharsets.UTF_8)
        exchange.getResponseHeaders.add("Content-Type", "application/json")
        exchange.sendResponseHeaders(200, body.length)
        val os = exchange.getResponseBody
        try os.write(body)
        finally os.close()
      else
        exchange.getResponseHeaders.add("Allow", "GET")
        exchange.sendResponseHeaders(405, -1)
    finally
      exchange.close()

  private final case class BlobMeta(key: String, size: Long, sha256: String, modifiedAt: String):
    def toJson: String =
      s"""{"key":${jsonString(key)},"size":$size,"sha256":"$sha256","modified_at":${jsonString(modifiedAt)}}"""

  private def listBlobs(dataDir: Path): List[BlobMeta] =
    val walk = Files.walk(dataDir)
    try
      walk
        .iterator()
        .asScala
        .filter(Files.isRegularFile(_))
        .map { path =>
          val key = dataDir.relativize(path).toString.replace(java.io.File.separatorChar, '/')
          BlobMeta(
            key = key,
            size = Files.size(path),
            sha256 = sha256Hex(path),
            modifiedAt = Files.getLastModifiedTime(path).toInstant.toString
          )
        }
        .toList
    finally walk.close()

  private def sha256Hex(path: Path): String =
    val digest = MessageDigest.getInstance("SHA-256")
    val in = new DigestInputStream(Files.newInputStream(path), digest)
    try in.transferTo(OutputStream.nullOutputStream())
    finally in.close()
    toHex(digest.digest())

  private def toHex(bytes: Array[Byte]): String =
    bytes.map(b => f"${b & 0xff}%02x").mkString

  private def jsonString(s: String): String =
    val sb = new StringBuilder("\"")
    s.foreach {
      case '"'          => sb.append("\\\"")
      case '\\'         => sb.append("\\\\")
      case c if c < ' ' => sb.append(f"\\u${c.toInt}%04x")
      case c            => sb.append(c)
    }
    sb.append('"')
    sb.toString
end Server
