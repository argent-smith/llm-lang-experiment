# syntax=docker/dockerfile:1

# --- build stage ---
FROM sbtscala/scala-sbt:eclipse-temurin-21.0.12_8_1.x AS build
WORKDIR /build

# Resolve dependencies first so this layer is cached across source changes.
COPY project project
COPY build.sbt .
RUN sbt update

COPY src src
RUN sbt test assembly

# --- runtime stage ---
FROM eclipse-temurin:21-jre-jammy AS runtime
WORKDIR /app
COPY --from=build /build/target/syncbox-server.jar /app/syncbox-server.jar

ENTRYPOINT ["java", "-jar", "/app/syncbox-server.jar"]
