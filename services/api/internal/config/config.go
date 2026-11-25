package config

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	Port                    int
	AuthIssuer              string
	AuthAudience            string
	AuthJWKSURL             string
	DatabaseURL             string
	DatabaseCredentialsFile string
	S3Endpoint              string
	S3Region                string
	S3Bucket                string
	S3CredentialsFile       string
	// TrainingKeyURL is OpenBao transit's read-key endpoint for glide-training, through the agent's local proxy.
	TrainingKeyURL string
}

// Load reads the environment, first filling unset keys from SECRETS_ENV_FILE when it is set.
func Load() (Config, error) {
	if path := os.Getenv("SECRETS_ENV_FILE"); path != "" {
		if err := loadEnvFile(path); err != nil {
			return Config{}, fmt.Errorf("load %s: %w", path, err)
		}
	}
	return Config{
		Port:                    intFromEnv("PORT", 8080),
		AuthIssuer:              get("AUTH_ISSUER", "https://auth.ghenti.com/api/auth"),
		AuthAudience:            get("AUTH_AUDIENCE", "https://glide.ghenti.com/v1"),
		AuthJWKSURL:             get("AUTH_JWKS_URL", "https://auth.ghenti.com/jwks"),
		DatabaseURL:             os.Getenv("DATABASE_URL"),
		DatabaseCredentialsFile: os.Getenv("DATABASE_CREDENTIALS_FILE"),
		S3Endpoint:              os.Getenv("S3_ENDPOINT"),
		S3Region:                get("S3_REGION", "garage"),
		S3Bucket:                os.Getenv("S3_BUCKET"),
		S3CredentialsFile:       os.Getenv("S3_CREDENTIALS_FILE"),
		TrainingKeyURL:          get("TRAINING_KEY_URL", "http://127.0.0.1:8100/v1/transit/keys/glide-training"),
	}, nil
}

// loadEnvFile sets KEY="value" lines that are not already in the environment.
func loadEnvFile(path string) error {
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	scanner := bufio.NewScanner(file)
	for number := 1; scanner.Scan(); number++ {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return fmt.Errorf("line %d is not KEY=value", number)
		}
		key = strings.TrimSpace(key)
		if unquoted, err := strconv.Unquote(value); err == nil {
			value = unquoted
		}
		if _, set := os.LookupEnv(key); !set {
			if err := os.Setenv(key, value); err != nil {
				return err
			}
		}
	}
	return scanner.Err()
}

func get(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func intFromEnv(name string, fallback int) int {
	value := strings.TrimSpace(os.Getenv(name))
	if value == "" {
		return fallback
	}
	parsed, err := strconv.Atoi(value)
	if err != nil || parsed < 0 {
		return fallback
	}
	return parsed
}
