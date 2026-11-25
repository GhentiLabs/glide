package app

import (
	"context"
	"net/http"
	"regexp"
	"strings"

	"github.com/coreos/go-oidc/v3/oidc"
)

type subKey struct{}

// subject guards the user ID, which goes into object keys and AAD strings.
var subject = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// newVerifier checks ES256 access tokens against the issuer's JWKS. The key set is
// cached and refetched when a token names a kid it has not seen.
func newVerifier(issuer, audience, jwksURL string) *oidc.IDTokenVerifier {
	keys := oidc.NewRemoteKeySet(context.Background(), jwksURL)
	return oidc.NewVerifier(issuer, keys, &oidc.Config{ClientID: audience, SupportedSigningAlgs: []string{oidc.ES256}})
}

// authenticate requires a valid bearer token and puts its subject in the context.
func (a *App) authenticate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		scheme, raw, _ := strings.Cut(r.Header.Get("Authorization"), " ")
		if strings.EqualFold(scheme, "Bearer") && raw != "" {
			if token, err := a.verifier.Verify(r.Context(), raw); err == nil && subject.MatchString(token.Subject) {
				next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), subKey{}, token.Subject)))
				return
			}
		}
		w.Header().Set("WWW-Authenticate", `Bearer realm="glide"`)
		writeError(w, r, fail(http.StatusUnauthorized, "unauthorized", "A valid Ghenti access token is required"))
	})
}

func sub(r *http.Request) string {
	value, _ := r.Context().Value(subKey{}).(string)
	return value
}
