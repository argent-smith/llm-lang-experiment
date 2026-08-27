ThisBuild / scalaVersion := "3.3.8"
ThisBuild / version := "0.1.0"
ThisBuild / organization := "syncbox"

lazy val root = (project in file("."))
  .settings(
    name := "syncbox-server",
    libraryDependencies += "org.scalameta" %% "munit" % "1.3.5" % Test,
    testFrameworks += new TestFramework("munit.Framework"),
    Compile / mainClass := Some("syncbox.server.Main"),
    assembly / assemblyJarName := "syncbox-server.jar",
    assembly / assemblyOutputPath := file("target") / "syncbox-server.jar",
    assembly / mainClass := Some("syncbox.server.Main"),
    assembly / assemblyMergeStrategy := {
      case PathList("META-INF", _*) => MergeStrategy.discard
      case _                        => MergeStrategy.first
    }
  )
