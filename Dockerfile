FROM golang:1.24-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN go build -o reservas-concurrentes .

FROM alpine:latest

WORKDIR /app

COPY --from=builder /app/reservas-concurrentes .
COPY --from=builder /app/config ./config
COPY --from=builder /app/database ./database

CMD ["./reservas-concurrentes"]