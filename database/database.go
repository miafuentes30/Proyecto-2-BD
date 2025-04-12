package database

import (
	"context"
	"fmt"
	"reservas-concurrentes/config"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

var pool *pgxpool.Pool

func Connect(cfg *config.Config) error {
	connString := fmt.Sprintf(
		"postgres://%s:%s@%s:%s/%s?sslmode=disable",
		cfg.DBUser, cfg.DBPassword, cfg.DBHost, cfg.DBPort, cfg.DBName,
	)

	config, err := pgxpool.ParseConfig(connString)
	if err != nil {
		return fmt.Errorf("error parsing connection string: %w", err)
	}

	config.MaxConns = 30
	config.MinConns = 5
	config.HealthCheckPeriod = time.Minute
	config.MaxConnLifetime = time.Hour

	pool, err = pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		return fmt.Errorf("error creating connection pool: %w", err)
	}

	return nil
}

func GetPool() *pgxpool.Pool {
	return pool
}

func Close() {
	if pool != nil {
		pool.Close()
	}
}
