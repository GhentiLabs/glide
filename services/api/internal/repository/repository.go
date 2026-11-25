package repository

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrations embed.FS

var (
	ErrNotFound  = errors.New("not found")
	ErrConflict  = errors.New("conflict")
	ErrForbidden = errors.New("forbidden")
)

type Record struct {
	ID       string `json:"id"`
	Kid      int32  `json:"kid"`
	Revision int32  `json:"revision"`
	Seq      int64  `json:"seq"`
	Deleted  bool   `json:"deleted"`
	Sealed   []byte `json:"sealed"` // base64 in JSON, null for tombstones
	HasAudio bool   `json:"hasAudio"`
}

type Consent struct {
	Enabled bool       `json:"enabled"`
	Since   *time.Time `json:"since"`
	Items   int64      `json:"items"`
}

type Account struct {
	KeyKid     int32   `json:"keyKid"`
	Records    int64   `json:"records"`
	AudioBytes int64   `json:"audioBytes"`
	Training   Consent `json:"training"`
}

type Repository struct {
	pool *pgxpool.Pool
}

// New connects to Postgres. When credentialsFile is set, every new connection
// re-reads it because the platform rotates short-lived database users.
func New(ctx context.Context, databaseURL, credentialsFile string) (*Repository, error) {
	cfg, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, err
	}
	cfg.MaxConnLifetime = 30 * time.Minute
	cfg.MaxConnLifetimeJitter = time.Minute
	if credentialsFile != "" {
		cfg.BeforeConnect = func(_ context.Context, conn *pgx.ConnConfig) error {
			raw, err := os.ReadFile(credentialsFile)
			if err != nil {
				return err
			}
			var creds struct {
				Username string `json:"username"`
				Password string `json:"password"`
			}
			if err := json.Unmarshal(raw, &creds); err != nil {
				return fmt.Errorf("parse database credentials: %w", err)
			}
			conn.User, conn.Password = creds.Username, creds.Password
			return nil
		}
	}
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &Repository{pool: pool}, nil
}

func (r *Repository) Close() { r.pool.Close() }

// Migrate applies embedded migrations in name order under an advisory lock so
// concurrent migrators wait for each other.
func (r *Repository) Migrate(ctx context.Context) error {
	conn, err := r.pool.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	const lockID = 4537210 // arbitrary, unique to this service's database
	if _, err := conn.Exec(ctx, "SELECT pg_advisory_lock($1)", lockID); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), "SELECT pg_advisory_unlock($1)", lockID) //nolint:errcheck
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	names, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	sort.Strings(names)
	for _, name := range names {
		version := strings.TrimSuffix(strings.TrimPrefix(name, "migrations/"), ".sql")
		var applied bool
		if err := conn.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)", version).Scan(&applied); err != nil {
			return err
		}
		if applied {
			continue
		}
		sql, err := migrations.ReadFile(name)
		if err != nil {
			return err
		}
		err = pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, "INSERT INTO schema_migrations (version) VALUES ($1)", version)
			return err
		})
		if err != nil {
			return fmt.Errorf("migration %s: %w", version, err)
		}
	}
	return nil
}

const recordColumns = "id::text, kid, revision, seq, deleted, sealed, has_audio"

func scanRecord(row pgx.Row) (Record, error) {
	var rec Record
	err := row.Scan(&rec.ID, &rec.Kid, &rec.Revision, &rec.Seq, &rec.Deleted, &rec.Sealed, &rec.HasAudio)
	if errors.Is(err, pgx.ErrNoRows) {
		return rec, ErrNotFound
	}
	return rec, err
}

// recordWrite runs fn holding this user's record lock, so seq values commit in the
// order they were taken and a listRecords cursor never skips a change.
func (r *Repository) recordWrite(ctx context.Context, sub string, fn func(pgx.Tx) error) error {
	return pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", sub); err != nil {
			return err
		}
		return fn(tx)
	})
}

// PutRecord creates (base 0) or replaces a record whose revision is base. A stale base
// returns the current record with ErrConflict; a missing record with base > 0 is ErrNotFound.
func (r *Repository) PutRecord(ctx context.Context, sub, id string, kid int32, sealed []byte, base int32) (Record, error) {
	var out Record
	err := r.recordWrite(ctx, sub, func(tx pgx.Tx) error {
		current, err := scanRecord(tx.QueryRow(ctx, "SELECT "+recordColumns+" FROM records WHERE sub = $1 AND id = $2", sub, id))
		switch {
		case errors.Is(err, ErrNotFound) && base == 0:
			out, err = scanRecord(tx.QueryRow(ctx, `INSERT INTO records (sub, id, kid, revision, sealed) VALUES ($1, $2, $3, 1, $4)
				RETURNING `+recordColumns, sub, id, kid, sealed))
			return err
		case err != nil:
			return err
		case current.Revision != base:
			out = current
			return ErrConflict
		}
		out, err = scanRecord(tx.QueryRow(ctx, `UPDATE records SET kid = $3, sealed = $4, deleted = false, revision = revision + 1,
			seq = nextval('record_seq'), updated_at = now() WHERE sub = $1 AND id = $2 RETURNING `+recordColumns, sub, id, kid, sealed))
		return err
	})
	return out, err
}

func (r *Repository) GetRecord(ctx context.Context, sub, id string) (Record, error) {
	return scanRecord(r.pool.QueryRow(ctx, "SELECT "+recordColumns+" FROM records WHERE sub = $1 AND id = $2", sub, id))
}

// DeleteRecord turns a record into a tombstone. Deleting a tombstone again changes nothing.
func (r *Repository) DeleteRecord(ctx context.Context, sub, id string) error {
	return r.recordWrite(ctx, sub, func(tx pgx.Tx) error {
		current, err := scanRecord(tx.QueryRow(ctx, "SELECT "+recordColumns+" FROM records WHERE sub = $1 AND id = $2", sub, id))
		if err != nil || current.Deleted {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE records SET deleted = true, sealed = NULL, has_audio = false, audio_bytes = 0,
			revision = revision + 1, seq = nextval('record_seq'), updated_at = now() WHERE sub = $1 AND id = $2`, sub, id)
		return err
	})
}

// SetAudio marks a live record as having audio of the given size and moves it up the change feed.
func (r *Repository) SetAudio(ctx context.Context, sub, id string, size int64) error {
	return r.recordWrite(ctx, sub, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE records SET has_audio = true, audio_bytes = $3, seq = nextval('record_seq'), updated_at = now()
			WHERE sub = $1 AND id = $2 AND NOT deleted`, sub, id, size)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

// ListRecords returns changes after the cursor, oldest first, and the next cursor when more remain.
func (r *Repository) ListRecords(ctx context.Context, sub string, after int64, limit int) ([]Record, *int64, error) {
	rows, err := r.pool.Query(ctx, "SELECT "+recordColumns+" FROM records WHERE sub = $1 AND seq > $2 ORDER BY seq LIMIT $3", sub, after, limit+1)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	items := []Record{}
	for rows.Next() {
		rec, err := scanRecord(rows)
		if err != nil {
			return nil, nil, err
		}
		items = append(items, rec)
	}
	if err := rows.Err(); err != nil {
		return nil, nil, err
	}
	if len(items) <= limit {
		return items, nil, nil
	}
	items = items[:limit]
	next := items[limit-1].Seq
	return items, &next, nil
}

func (r *Repository) DeleteAllRecords(ctx context.Context, sub string) error {
	return r.recordWrite(ctx, sub, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, "DELETE FROM records WHERE sub = $1", sub)
		return err
	})
}

func (r *Repository) Account(ctx context.Context, sub string) (Account, error) {
	var account Account
	err := r.pool.QueryRow(ctx, `SELECT COALESCE(max(kid), 0), count(*) FILTER (WHERE NOT deleted), COALESCE(sum(audio_bytes), 0)::bigint
		FROM records WHERE sub = $1`, sub).Scan(&account.KeyKid, &account.Records, &account.AudioBytes)
	if err != nil {
		return account, err
	}
	account.Training, err = r.Consent(ctx, sub)
	return account, err
}

func (r *Repository) Consent(ctx context.Context, sub string) (Consent, error) {
	var consent Consent
	err := r.pool.QueryRow(ctx, `SELECT COALESCE((SELECT enabled FROM training_consent WHERE sub = $1), false),
		(SELECT since FROM training_consent WHERE sub = $1), (SELECT count(*) FROM training_items WHERE sub = $1)`, sub).
		Scan(&consent.Enabled, &consent.Since, &consent.Items)
	return consent, err
}

// SetConsent turns sharing on or off. Off removes every item row in the same
// transaction; the caller then deletes the objects.
func (r *Repository) SetConsent(ctx context.Context, sub string, enabled bool) (Consent, error) {
	err := pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO training_consent (sub, enabled, since) VALUES ($1, $2, CASE WHEN $2 THEN now() END)
			ON CONFLICT (sub) DO UPDATE SET enabled = $2,
			since = CASE WHEN NOT $2 THEN NULL WHEN training_consent.enabled THEN training_consent.since ELSE now() END`, sub, enabled); err != nil {
			return err
		}
		if enabled {
			return nil
		}
		_, err := tx.Exec(ctx, "DELETE FROM training_items WHERE sub = $1", sub)
		return err
	})
	if err != nil {
		return Consent{}, err
	}
	return r.Consent(ctx, sub)
}

// PutTrainingItem records an uploaded item, or returns ErrForbidden when consent is off.
// It holds the consent row so turning sharing off waits for it and then removes it.
func (r *Repository) PutTrainingItem(ctx context.Context, sub, id string, keyVersion int32, size int64) error {
	return pgx.BeginFunc(ctx, r.pool, func(tx pgx.Tx) error {
		var enabled bool
		err := tx.QueryRow(ctx, "SELECT enabled FROM training_consent WHERE sub = $1 FOR SHARE", sub).Scan(&enabled)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !enabled) {
			return ErrForbidden
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `INSERT INTO training_items (sub, id, key_version, bytes) VALUES ($1, $2, $3, $4)
			ON CONFLICT (sub, id) DO UPDATE SET key_version = $3, bytes = $4, updated_at = now()`, sub, id, keyVersion, size)
		return err
	})
}

func (r *Repository) DeleteTrainingItem(ctx context.Context, sub, id string) error {
	_, err := r.pool.Exec(ctx, "DELETE FROM training_items WHERE sub = $1 AND id = $2", sub, id)
	return err
}
