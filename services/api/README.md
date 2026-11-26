# Glide API

Sync and training uploads for Glide at `glide.ghenti.com`. The contract is [openapi.yaml](openapi.yaml).
It stores sealed records and audio and never decrypts them; it checks only their shape and size.

## Run

```sh
go run ./cmd/server migrate   # apply migrations, then exit
go run ./cmd/server           # serve on :8080
```

Image: `docker build -t ghenti/glide-api services/api` (static binary `/glide-api` on distroless, port 8080).
On the ghenti-app chart: `command: [/glide-api]`, `migrate: [/glide-api, migrate]`, `probePath: /health`.

## Environment

| Variable | Default | |
|---|---|---|
| `PORT` | `8080` | |
| `SECRETS_ENV_FILE` | | `KEY="value"` file read first (`/run/secrets/app.env` in the cluster) |
| `AUTH_ISSUER` | `https://auth.ghenti.com/api/auth` | Token `iss` |
| `AUTH_AUDIENCE` | `https://glide.ghenti.com/v1` | Must be in the token's `aud` |
| `AUTH_JWKS_URL` | `https://auth.ghenti.com/jwks` | ES256 keys, refetched on an unknown `kid` |
| `DATABASE_URL` | | Postgres URL |
| `DATABASE_CREDENTIALS_FILE` | | `{"username","password"}`, re-read per connection (`/run/secrets/db.json`) |
| `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET` | region `garage` | Garage bucket for `glide/<sub>/audio/<id>` and `training/<sub>/<id>` |
| `S3_CREDENTIALS_FILE` | | `{"access_key_id","secret_access_key"}`, re-read as it rotates (`/run/secrets/s3.json`) |
| `TRAINING_KEY_URL` | `http://127.0.0.1:8100/v1/transit/keys/glide-training` | OpenBao transit read-key, through the agent proxy |

## Test

Tests need a Postgres server; each test creates and drops its own database. S3, the JWKS and OpenBao are local fakes.

```sh
TEST_DATABASE_URL='postgres://postgres@127.0.0.1:5432/postgres?sslmode=disable' go test ./...
```
