FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /hako-server ./cmd/hako-server

FROM alpine:3.23
RUN apk add --no-cache ca-certificates && addgroup -g 10001 hako && adduser -D -u 10001 -G hako hako \
    && mkdir -p /app/data && chown hako:hako /app/data
WORKDIR /app
COPY --from=build /hako-server /usr/local/bin/hako-server
USER hako
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["hako-server"]
