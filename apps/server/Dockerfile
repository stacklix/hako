FROM node:24-alpine AS notification-build
WORKDIR /app/notifications
COPY web/notifications/package.json web/notifications/package-lock.json ./
RUN npm ci
COPY web/notifications/ ./
RUN npm run build

FROM golang:1.26-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /sora-server ./cmd/sora-server

FROM alpine:3.23
RUN apk add --no-cache ca-certificates && addgroup -g 10001 sora && adduser -D -u 10001 -G sora sora \
    && mkdir -p /app/data && chown sora:sora /app/data
WORKDIR /app
COPY --from=build /sora-server /usr/local/bin/sora-server
COPY --from=notification-build /app/notifications/dist/web /app/notifications-web
ENV HAKO_NOTIFICATION_WEB_DIR=/app/notifications-web
USER sora
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
ENTRYPOINT ["sora-server"]
