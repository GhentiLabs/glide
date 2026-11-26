package app

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/GhentiLabs/glide/services/api/internal/repository"
)

type requestIDKey struct{}

type apiError struct {
	status        int
	code, message string
}

func (e *apiError) Error() string { return e.message }

func fail(status int, code, message string) error {
	return &apiError{status: status, code: code, message: message}
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if value != nil {
		_ = json.NewEncoder(w).Encode(value)
	}
}

func respond(w http.ResponseWriter, r *http.Request, status int, value any, err error) {
	switch {
	case err != nil:
		writeError(w, r, err)
	case status == http.StatusNoContent:
		w.WriteHeader(status)
	default:
		writeJSON(w, status, value)
	}
}

// writeError sends the contract's {error, message} body. Unexpected errors are
// logged by request ID and never echoed.
func writeError(w http.ResponseWriter, r *http.Request, err error) {
	var apiErr *apiError
	switch {
	case errors.As(err, &apiErr):
	case errors.Is(err, repository.ErrNotFound):
		apiErr = &apiError{http.StatusNotFound, "not_found", "Not found"}
	case errors.Is(err, repository.ErrForbidden):
		apiErr = &apiError{http.StatusForbidden, "forbidden", "Training sharing is off"}
	default:
		log.Printf("requestId=%s method=%s path=%s error=%v", r.Context().Value(requestIDKey{}), r.Method, r.URL.Path, err)
		apiErr = &apiError{http.StatusInternalServerError, "internal", "An unexpected error occurred"}
	}
	writeJSON(w, apiErr.status, map[string]string{"error": apiErr.code, "message": apiErr.message})
}

func appSiteAssociation(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"webcredentials":{"apps":["KSH6P6Y39N.com.ghentilabs.glide"]}}`))
}

// returnPage is what a callback link shows if it opens in a browser instead of Glide.
// It never reads the query or fragment.
func returnPage(message string) http.HandlerFunc {
	page := fmt.Sprintf(`<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Glide</title></head>
<body><h1>Glide</h1><p>%s</p></body>
</html>
`, html.EscapeString(message))
	return func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write([]byte(page))
	}
}

func securityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Security-Policy", "default-src 'none'; frame-ancestors 'none'")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		next.ServeHTTP(w, r)
	})
}

func requestID(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		value := strings.TrimSpace(r.Header.Get("X-Request-ID"))
		if value == "" || len(value) > 128 {
			value = fmt.Sprintf("glide-%d", time.Now().UnixNano())
		}
		w.Header().Set("X-Request-ID", value)
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), requestIDKey{}, value)))
	})
}

// requestLogging logs the path only: no query, headers or body.
func requestLogging(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("requestId=%s method=%s path=%s durationMs=%d", r.Context().Value(requestIDKey{}), r.Method, r.URL.Path, time.Since(started).Milliseconds())
	})
}

func recovery(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if recovered := recover(); recovered != nil {
				log.Printf("requestId=%s panic=%v", r.Context().Value(requestIDKey{}), recovered)
				writeError(w, r, fail(http.StatusInternalServerError, "internal", "An unexpected error occurred"))
			}
		}()
		next.ServeHTTP(w, r)
	})
}
