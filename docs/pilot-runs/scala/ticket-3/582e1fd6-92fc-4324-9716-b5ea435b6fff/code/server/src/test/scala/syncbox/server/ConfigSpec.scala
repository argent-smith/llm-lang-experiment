package syncbox.server

import munit.FunSuite

import java.nio.file.Paths

class ConfigSpec extends FunSuite:

  test("fails when --data-dir is missing from both flags and env") {
    val result = Config.parse(Array("--port", "9090"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }

  test("parses --data-dir and --port from flags") {
    val result = Config.parse(Array("--data-dir", "/tmp/data", "--port", "9090"), Map.empty)
    assertEquals(result, Right(Config(Paths.get("/tmp/data"), 9090)))
  }

  test("defaults --port to 8080 when not specified") {
    val result = Config.parse(Array("--data-dir", "/tmp/data"), Map.empty)
    assertEquals(result, Right(Config(Paths.get("/tmp/data"), Config.DefaultPort)))
  }

  test("falls back to SYNCBOX_DATA_DIR and SYNCBOX_PORT env vars") {
    val env = Map("SYNCBOX_DATA_DIR" -> "/env/data", "SYNCBOX_PORT" -> "9191")
    val result = Config.parse(Array.empty, env)
    assertEquals(result, Right(Config(Paths.get("/env/data"), 9191)))
  }

  test("flags take precedence over env vars") {
    val env = Map("SYNCBOX_DATA_DIR" -> "/env/data", "SYNCBOX_PORT" -> "9191")
    val result = Config.parse(Array("--data-dir", "/flag/data", "--port", "7000"), env)
    assertEquals(result, Right(Config(Paths.get("/flag/data"), 7000)))
  }

  test("uses SYNCBOX_DATA_DIR with flag-provided --port") {
    val env = Map("SYNCBOX_DATA_DIR" -> "/env/data")
    val result = Config.parse(Array("--port", "7000"), env)
    assertEquals(result, Right(Config(Paths.get("/env/data"), 7000)))
  }

  test("rejects a non-numeric --port value") {
    val result = Config.parse(Array("--data-dir", "/tmp/data", "--port", "notanumber"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }

  test("rejects an out-of-range --port value") {
    val result = Config.parse(Array("--data-dir", "/tmp/data", "--port", "70000"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }

  test("rejects a zero --port value") {
    val result = Config.parse(Array("--data-dir", "/tmp/data", "--port", "0"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }

  test("rejects an unknown flag") {
    val result = Config.parse(Array("--data-dir", "/tmp/data", "--bogus", "x"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }

  test("rejects --data-dir with a missing value") {
    val result = Config.parse(Array("--data-dir"), Map.empty)
    assert(result.isLeft, s"expected Left, got $result")
  }
end ConfigSpec
