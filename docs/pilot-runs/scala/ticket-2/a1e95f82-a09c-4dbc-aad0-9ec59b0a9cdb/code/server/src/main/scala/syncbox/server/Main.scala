package syncbox.server

import java.nio.file.Files
import java.util.concurrent.CountDownLatch

object Main:
  def main(args: Array[String]): Unit =
    Config.parse(args, sys.env) match
      case Left(error) =>
        System.err.println(s"syncbox-server: $error")
        sys.exit(1)
      case Right(config) =>
        Files.createDirectories(config.dataDir)
        val server = Server.start(config)
        System.err.println(
          s"syncbox-server: listening on port ${server.getAddress.getPort}, data-dir=${config.dataDir}"
        )

        val shutdownLatch = new CountDownLatch(1)
        Runtime.getRuntime.addShutdownHook(new Thread(() =>
          server.stop(0)
          shutdownLatch.countDown()
        ))
        shutdownLatch.await()
end Main
