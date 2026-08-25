FROM golang:1.22-alpine AS base
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY . .

FROM base AS test
CMD ["go", "test", "./..."]

FROM base AS build
RUN CGO_ENABLED=0 go build -o /out/syncbox-server ./cmd/server

FROM alpine:3.20 AS runtime
COPY --from=build /out/syncbox-server /usr/local/bin/syncbox-server
ENTRYPOINT ["/usr/local/bin/syncbox-server"]
