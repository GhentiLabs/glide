package app

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/GhentiLabs/glide/services/api/internal/config"
	"github.com/GhentiLabs/glide/services/api/internal/repository"
	"github.com/coreos/go-oidc/v3/oidc"
)

const (
	maxRecordBytes   = 256 << 10 // decoded sealed record
	maxAudioBytes    = 8 << 20
	maxTrainingBytes = 8 << 20 // decoded sealed training item
	minSealedBytes   = 1 + 12 + 16
	sealedVersion    = 0x01
	wrappedKeyBytes  = 512 // RSA-4096 OAEP output
	jsonSlack        = 4 << 10
	defaultPageSize  = 200
	maxPageSize      = 500
)

type App struct {
	repo     *repository.Repository
	objects  *objects
	verifier *oidc.IDTokenVerifier
	training *trainingKeys
}

func New(cfg config.Config, repo *repository.Repository) http.Handler {
	a := &App{
		repo:     repo,
		objects:  newObjects(cfg),
		verifier: newVerifier(cfg.AuthIssuer, cfg.AuthAudience, cfg.AuthJWKSURL),
		training: &trainingKeys{url: cfg.TrainingKeyURL, client: &http.Client{Timeout: 10 * time.Second}},
	}
	root := http.NewServeMux()
	root.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "service": "glide-api"})
	})
	root.HandleFunc("GET /.well-known/apple-app-site-association", appSiteAssociation)
	root.HandleFunc("GET /auth/callback", returnPage("Return to Glide to finish signing in."))
	root.HandleFunc("GET /keys/callback", returnPage("Return to Glide to finish turning on sync."))

	api := http.NewServeMux()
	api.HandleFunc("GET /account", a.getAccount)
	api.HandleFunc("GET /records", a.listRecords)
	api.HandleFunc("DELETE /records", a.deleteAllSynced)
	api.HandleFunc("PUT /records/{id}", a.putRecord)
	api.HandleFunc("DELETE /records/{id}", a.deleteRecord)
	api.HandleFunc("PUT /audio/{id}", a.putAudio)
	api.HandleFunc("GET /audio/{id}", a.getAudio)
	api.HandleFunc("GET /training/key", a.getTrainingKey)
	api.HandleFunc("PUT /training/consent", a.setTrainingConsent)
	api.HandleFunc("PUT /training/items/{id}", a.putTrainingItem)
	api.HandleFunc("DELETE /training/items/{id}", a.deleteTrainingItem)
	api.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		writeError(w, r, fail(http.StatusNotFound, "not_found", "No such endpoint"))
	})
	root.Handle("/v1/", a.authenticate(http.StripPrefix("/v1", api)))
	return securityHeaders(requestID(recovery(requestLogging(root))))
}

func (a *App) getAccount(w http.ResponseWriter, r *http.Request) {
	account, err := a.repo.Account(r.Context(), sub(r))
	respond(w, r, http.StatusOK, account, err)
}

func (a *App) listRecords(w http.ResponseWriter, r *http.Request) {
	query := r.URL.Query()
	after, err := strconv.ParseInt(query.Get("after"), 10, 64)
	if err != nil || after < 0 {
		writeError(w, r, fail(http.StatusBadRequest, "bad_request", "after must be a cursor of 0 or more"))
		return
	}
	limit := defaultPageSize
	if raw := query.Get("limit"); raw != "" {
		if limit, err = strconv.Atoi(raw); err != nil || limit < 1 || limit > maxPageSize {
			writeError(w, r, fail(http.StatusBadRequest, "bad_request", "limit must be from 1 to 500"))
			return
		}
	}
	items, next, err := a.repo.ListRecords(r.Context(), sub(r), after, limit)
	respond(w, r, http.StatusOK, map[string]any{"items": items, "next": next}, err)
}

func (a *App) deleteAllSynced(w http.ResponseWriter, r *http.Request) {
	err := a.repo.DeleteAllRecords(r.Context(), sub(r))
	if err == nil {
		err = a.objects.deletePrefix(r.Context(), "glide/"+sub(r)+"/")
	}
	respond(w, r, http.StatusNoContent, nil, err)
}

func (a *App) putRecord(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	var input struct {
		Kid          int32  `json:"kid"`
		Sealed       string `json:"sealed"`
		BaseRevision *int32 `json:"baseRevision"`
	}
	if err == nil {
		err = decodeJSON(w, r, base64.StdEncoding.EncodedLen(maxRecordBytes)+jsonSlack, &input)
	}
	if err == nil && (input.Kid < 1 || input.BaseRevision == nil || *input.BaseRevision < 0) {
		err = fail(http.StatusBadRequest, "bad_request", "kid of 1 or more and baseRevision of 0 or more are required")
	}
	var sealed []byte
	if err == nil {
		sealed, err = decodeSealed(input.Sealed, maxRecordBytes)
	}
	if err != nil {
		writeError(w, r, err)
		return
	}
	record, err := a.repo.PutRecord(r.Context(), sub(r), id, input.Kid, sealed, *input.BaseRevision)
	if errors.Is(err, repository.ErrConflict) {
		writeJSON(w, http.StatusConflict, record)
		return
	}
	if errors.Is(err, repository.ErrNotFound) {
		err = fail(http.StatusNotFound, "not_found", "No such record; send baseRevision 0 to create it")
	}
	respond(w, r, http.StatusOK, record, err)
}

func (a *App) deleteRecord(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err == nil {
		err = a.repo.DeleteRecord(r.Context(), sub(r), id)
	}
	if err == nil {
		err = a.objects.delete(r.Context(), audioKey(sub(r), id))
	}
	respond(w, r, http.StatusNoContent, nil, err)
}

func (a *App) putAudio(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	if err == nil {
		err = a.requireLiveRecord(r, id)
	}
	var body []byte
	if err == nil {
		body, err = readBody(w, r, maxAudioBytes)
	}
	if err == nil {
		err = checkSealed(body)
	}
	if err == nil {
		err = a.objects.put(r.Context(), audioKey(sub(r), id), body, nil)
	}
	if err == nil {
		// The record may have been deleted while the audio uploaded.
		if err = a.repo.SetAudio(r.Context(), sub(r), id, int64(len(body))); errors.Is(err, repository.ErrNotFound) {
			_ = a.objects.delete(r.Context(), audioKey(sub(r), id))
		}
	}
	respond(w, r, http.StatusNoContent, nil, err)
}

func (a *App) requireLiveRecord(r *http.Request, id string) error {
	record, err := a.repo.GetRecord(r.Context(), sub(r), id)
	if err == nil && record.Deleted {
		return repository.ErrNotFound
	}
	return err
}

func (a *App) getAudio(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	var record repository.Record
	if err == nil {
		record, err = a.repo.GetRecord(r.Context(), sub(r), id)
	}
	if err == nil && (record.Deleted || !record.HasAudio) {
		err = repository.ErrNotFound
	}
	var body io.ReadCloser
	var size int64
	if err == nil {
		body, size, err = a.objects.get(r.Context(), audioKey(sub(r), id))
	}
	if err != nil {
		writeError(w, r, err)
		return
	}
	defer body.Close()
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
	w.Header().Set("Cache-Control", "no-store")
	_, _ = io.Copy(w, body)
}

func (a *App) getTrainingKey(w http.ResponseWriter, r *http.Request) {
	key, err := a.training.get(r.Context())
	respond(w, r, http.StatusOK, key, err)
}

func (a *App) setTrainingConsent(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Enabled *bool `json:"enabled"`
	}
	err := decodeJSON(w, r, jsonSlack, &input)
	if err == nil && input.Enabled == nil {
		err = fail(http.StatusBadRequest, "bad_request", "enabled is required")
	}
	var consent repository.Consent
	var removed []string
	if err == nil {
		consent, removed, err = a.repo.SetConsent(r.Context(), sub(r), *input.Enabled)
	}
	for _, id := range removed {
		if err == nil {
			err = a.objects.delete(r.Context(), trainingKey(id))
		}
	}
	respond(w, r, http.StatusOK, consent, err)
}

// putTrainingItem stores wrappedKey (512 bytes) followed by the sealed item, as sent, at
// training/<id>. The account is recorded only in the database, so turning sharing off can delete it.
func (a *App) putTrainingItem(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	keyVersion, convErr := strconv.Atoi(r.URL.Query().Get("keyVersion"))
	if err == nil && (convErr != nil || keyVersion < 1 || keyVersion > math.MaxInt32) {
		err = fail(http.StatusBadRequest, "bad_request", "keyVersion of 1 or more is required")
	}
	if err == nil {
		// Refuse before reading the body; PutTrainingItem checks both again under lock.
		var consent repository.Consent
		if consent, err = a.repo.Consent(r.Context(), sub(r)); err == nil && !consent.Enabled {
			err = repository.ErrForbidden
		}
	}
	if err == nil {
		var owns bool
		if owns, err = a.repo.OwnsTrainingItem(r.Context(), sub(r), id); err == nil && !owns {
			err = repository.ErrForbidden
		}
	}
	var body []byte
	if err == nil {
		body, err = readBody(w, r, wrappedKeyBytes+maxTrainingBytes)
	}
	if err == nil && len(body) < wrappedKeyBytes {
		err = fail(http.StatusBadRequest, "bad_request", "the body must start with a 512-byte RSA-4096 wrapped key")
	}
	if err == nil {
		err = checkSealed(body[wrappedKeyBytes:])
	}
	if err == nil {
		err = a.repo.PutTrainingItem(r.Context(), sub(r), id, int32(keyVersion), int64(len(body)))
	}
	if err == nil {
		err = a.objects.put(r.Context(), trainingKey(id), body, map[string]string{"key-version": strconv.Itoa(keyVersion)})
	}
	if err == nil {
		// Consent may have been turned off while the item uploaded.
		if still, checkErr := a.repo.HasTrainingItem(r.Context(), sub(r), id); checkErr == nil && !still {
			_ = a.objects.delete(r.Context(), trainingKey(id))
			err = repository.ErrForbidden
		}
	}
	respond(w, r, http.StatusNoContent, nil, err)
}

func (a *App) deleteTrainingItem(w http.ResponseWriter, r *http.Request) {
	id, err := pathID(r)
	var owned bool
	if err == nil {
		owned, err = a.repo.HasTrainingItem(r.Context(), sub(r), id)
	}
	if err == nil && owned {
		err = a.objects.delete(r.Context(), trainingKey(id))
	}
	if err == nil && owned {
		err = a.repo.DeleteTrainingItem(r.Context(), sub(r), id)
	}
	respond(w, r, http.StatusNoContent, nil, err)
}

var uuidPattern = regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`)

// pathID returns the {id} UUID in lower case, the form used in object keys.
func pathID(r *http.Request) (string, error) {
	id := r.PathValue("id")
	if !uuidPattern.MatchString(id) {
		return "", fail(http.StatusBadRequest, "bad_request", "id must be a UUID")
	}
	return strings.ToLower(id), nil
}

// readBody reads at most limit bytes, refusing a larger declared length before reading anything.
func readBody(w http.ResponseWriter, r *http.Request, limit int) ([]byte, error) {
	if r.ContentLength > int64(limit) {
		return nil, fail(http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("The body is larger than %d bytes", limit))
	}
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, int64(limit)))
	var tooLarge *http.MaxBytesError
	if errors.As(err, &tooLarge) {
		return nil, fail(http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("The body is larger than %d bytes", limit))
	}
	return body, err
}

func decodeJSON(w http.ResponseWriter, r *http.Request, limit int, value any) error {
	body, err := readBody(w, r, limit)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, value); err != nil {
		return fail(http.StatusBadRequest, "bad_request", "The body is not valid JSON for this request")
	}
	return nil
}

// decodeSealed checks shape only: base64, version byte, room for nonce and tag, and size.
func decodeSealed(value string, limit int) ([]byte, error) {
	sealed, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return nil, fail(http.StatusBadRequest, "bad_request", "sealed must be base64")
	}
	if len(sealed) > limit {
		return nil, fail(http.StatusRequestEntityTooLarge, "too_large", fmt.Sprintf("sealed is larger than %d bytes", limit))
	}
	return sealed, checkSealed(sealed)
}

func checkSealed(sealed []byte) error {
	if len(sealed) < minSealedBytes || sealed[0] != sealedVersion {
		return fail(http.StatusBadRequest, "bad_request", "sealed must be version 1, nonce, ciphertext and tag")
	}
	return nil
}
