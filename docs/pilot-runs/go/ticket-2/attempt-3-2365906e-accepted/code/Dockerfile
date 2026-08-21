FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod ./
COPY cmd ./cmd
COPY internal ./internal
RUN CGO_ENABLED=0 go build -o /out/syncbox-server ./cmd/server

FROM alpine:3.20
RUN adduser -D -u 10001 syncbox
COPY --from=build /out/syncbox-server /usr/local/bin/syncbox-server
USER syncbox
ENTRYPOINT ["/usr/local/bin/syncbox-server"]
