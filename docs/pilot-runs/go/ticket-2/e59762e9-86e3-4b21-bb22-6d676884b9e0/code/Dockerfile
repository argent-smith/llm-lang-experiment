FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN go build -o /out/syncbox-server ./cmd/server

FROM alpine:3.20
COPY --from=build /out/syncbox-server /usr/local/bin/syncbox-server
ENTRYPOINT ["/usr/local/bin/syncbox-server"]
