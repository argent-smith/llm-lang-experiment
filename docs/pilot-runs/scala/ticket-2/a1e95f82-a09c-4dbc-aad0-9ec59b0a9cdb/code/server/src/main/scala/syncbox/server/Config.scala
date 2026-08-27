package syncbox.server

import java.nio.file.{Path, Paths}

final case class Config(dataDir: Path, port: Int)

object Config:
  val DefaultPort = 8080

  /** Parses server configuration from CLI args, falling back to environment
    * variables (SYNCBOX_DATA_DIR / SYNCBOX_PORT) when a flag is absent.
    * Flags take precedence over environment variables.
    */
  def parse(args: Array[String], env: Map[String, String]): Either[String, Config] =
    for
      parsed <- parseArgs(args.toList, None, None)
      (dataDirArg, portArg) = parsed
      dataDirStr <- dataDirArg
        .orElse(env.get("SYNCBOX_DATA_DIR"))
        .toRight("--data-dir is required (or set SYNCBOX_DATA_DIR)")
      portStr = portArg.orElse(env.get("SYNCBOX_PORT"))
      port <- portStr.fold[Either[String, Int]](Right(DefaultPort))(parsePort)
    yield Config(Paths.get(dataDirStr), port)

  private def parsePort(s: String): Either[String, Int] =
    s.toIntOption
      .filter(p => p >= 1 && p <= 65535)
      .toRight(s"invalid --port value: '$s'")

  private def parseArgs(
      args: List[String],
      dataDir: Option[String],
      port: Option[String]
  ): Either[String, (Option[String], Option[String])] =
    args match
      case Nil =>
        Right((dataDir, port))
      case "--data-dir" :: value :: rest =>
        parseArgs(rest, Some(value), port)
      case "--port" :: value :: rest =>
        parseArgs(rest, dataDir, Some(value))
      case "--data-dir" :: Nil =>
        Left("--data-dir requires a value")
      case "--port" :: Nil =>
        Left("--port requires a value")
      case unknown :: _ =>
        Left(s"unknown argument: $unknown")
end Config
