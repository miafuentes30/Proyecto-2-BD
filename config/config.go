package config

type Config struct {
	DBHost     string
	DBPort     string
	DBUser     string
	DBPassword string
	DBName     string
}

func Load() *Config {
	return &Config{
		DBHost:     "db",
		DBPort:     "5432",
		DBUser:     "postgres",
		DBPassword: "postgres",
		DBName:     "ddl",
	}
}
