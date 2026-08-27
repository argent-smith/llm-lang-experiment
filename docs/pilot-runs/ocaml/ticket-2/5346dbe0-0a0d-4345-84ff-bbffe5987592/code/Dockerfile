# syntax=docker/dockerfile:1
FROM ocaml/opam:debian-12-ocaml-5.2 AS build

WORKDIR /build
RUN sudo chown opam:opam /build

RUN sudo apt-get update \
    && sudo apt-get install -y --no-install-recommends libev-dev libssl-dev pkg-config \
    && sudo rm -rf /var/lib/apt/lists/*

RUN opam update \
    && opam install -y dune dream sha yojson

COPY --chown=opam:opam server/dune-project ./dune-project
COPY --chown=opam:opam server/lib ./lib
COPY --chown=opam:opam server/bin ./bin
COPY --chown=opam:opam server/test ./test

RUN opam exec -- dune build ./bin/main.exe
RUN opam exec -- dune runtest

FROM debian:12-slim AS runtime

RUN apt-get update \
    && apt-get install -y --no-install-recommends libev4 ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /build/_build/default/bin/main.exe /usr/local/bin/syncbox-server

ENTRYPOINT ["/usr/local/bin/syncbox-server"]
