# Dockerfile.prebuilt
# Gunakan ini jika Anda sudah punya binary siap pakai di ./build/nivora-api
# Pastikan binary dibangun untuk linux/amd64 dengan CGO disabled jika mau image minimal.
# Contoh build lokal:
#   CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o build/nivora-api main.go

FROM alpine:3.20

WORKDIR /app

# Install paket minimal (tzdata untuk zona waktu, wget untuk healthcheck)
RUN apk add --no-cache tzdata ca-certificates wget && \
	addgroup -S app && adduser -S app -G app

ENV TZ=Asia/Jakarta

# Salin binary prebuilt
COPY build/nivora-api ./nivora-api

EXPOSE 8080

USER app

ENTRYPOINT ["/app/nivora-api"]
