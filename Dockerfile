# Gunakan image Go untuk build
FROM golang:1.21 AS builder

WORKDIR /app

# Copy semua file ke container
COPY . .

# Build binary
RUN go build -o build/nivora-api main.go

# Gunakan image yang lebih ringan untuk menjalankan binary
FROM ubuntu:22.04

WORKDIR /app

# Copy binary dari builder
COPY --from=builder /app/build/nivora-api ./nivora-api

# Expose port sesuai ecosystem.config.js
EXPOSE 59152

# Jalankan aplikasi
CMD ["./nivora-api"]
