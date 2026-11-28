package app

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GhentiLabs/glide/services/api/internal/config"
	"github.com/GhentiLabs/glide/services/api/internal/repository"
	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"github.com/jackc/pgx/v5"
)

const (
	issuer   = "https://auth.test/api/auth"
	audience = "https://glide.test/v1"
	bucket   = "glide"
)

// fakeS3 is a path-style object store with just the calls the service makes.
type fakeS3 struct {
	mu      sync.Mutex
	objects map[string][]byte
	meta    map[string]http.Header
}

func (f *fakeS3) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	key := strings.TrimPrefix(r.URL.Path, "/"+bucket+"/")
	switch {
	case r.Method == http.MethodGet && r.URL.Query().Get("list-type") == "2":
		type content struct{ Key string }
		result := struct {
			XMLName  xml.Name `xml:"ListBucketResult"`
			Contents []content
		}{}
		for name := range f.objects {
			if strings.HasPrefix(name, r.URL.Query().Get("prefix")) {
				result.Contents = append(result.Contents, content{name})
			}
		}
		_ = xml.NewEncoder(w).Encode(result)
	case r.Method == http.MethodPut:
		body, _ := io.ReadAll(r.Body)
		f.objects[key], f.meta[key] = body, r.Header.Clone()
	case r.Method == http.MethodGet:
		body, ok := f.objects[key]
		if !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`<Error><Code>NoSuchKey</Code></Error>`))
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		_, _ = w.Write(body)
	case r.Method == http.MethodDelete:
		delete(f.objects, key)
		w.WriteHeader(http.StatusNoContent)
	default:
		w.WriteHeader(http.StatusNotImplemented)
	}
}

func (f *fakeS3) keys(prefix string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for name := range f.objects {
		if strings.HasPrefix(name, prefix) {
			out = append(out, name)
		}
	}
	sort.Strings(out)
	return out
}

type testEnv struct {
	handler      http.Handler
	s3           *fakeS3
	signingKey   *ecdsa.PrivateKey
	kid          string
	transitCalls *atomic.Int32
	rotate       func() // serve and sign with a new key
}

func newEnv(t *testing.T) *testEnv {
	t.Helper()
	env := &testEnv{s3: &fakeS3{objects: map[string][]byte{}, meta: map[string]http.Header{}}, transitCalls: &atomic.Int32{}}
	var keysMu sync.Mutex
	newKey := func(kid string) {
		key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
		keysMu.Lock()
		env.signingKey, env.kid = key, kid
		keysMu.Unlock()
	}
	newKey("k1")
	env.rotate = func() { newKey("k2") }
	jwks := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		keysMu.Lock()
		defer keysMu.Unlock()
		_ = json.NewEncoder(w).Encode(jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &env.signingKey.PublicKey, KeyID: env.kid, Algorithm: "ES256", Use: "sig"}}})
	}))
	t.Cleanup(jwks.Close)
	s3Server := httptest.NewServer(env.s3)
	t.Cleanup(s3Server.Close)
	transit := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		env.transitCalls.Add(1)
		_, _ = w.Write([]byte(`{"data":{"latest_version":2,"keys":{"1":{"public_key":"OLD"},"2":{"public_key":"-----BEGIN PUBLIC KEY-----\nNEW\n-----END PUBLIC KEY-----\n"}}}}`))
	}))
	t.Cleanup(transit.Close)

	credentials := filepath.Join(t.TempDir(), "s3.json")
	if err := os.WriteFile(credentials, []byte(`{"access_key_id":"GKtest","secret_access_key":"test"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config.Config{
		AuthIssuer: issuer, AuthAudience: audience, AuthJWKSURL: jwks.URL,
		S3Endpoint: s3Server.URL, S3Region: "garage", S3Bucket: bucket, S3CredentialsFile: credentials,
		TrainingKeyURL: transit.URL,
	}
	env.handler = New(cfg, testRepository(t))
	return env
}

// testRepository migrates a fresh database on the TEST_DATABASE_URL server and drops it afterwards.
func testRepository(t *testing.T) *repository.Repository {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		t.Skip("TEST_DATABASE_URL is not set")
	}
	ctx := context.Background()
	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatal(err)
	}
	name := fmt.Sprintf("glide_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatal(err)
	}
	dbURL, err := url.Parse(base)
	if err != nil {
		t.Fatal(err)
	}
	dbURL.Path = "/" + name
	repo, err := repository.New(ctx, dbURL.String(), "")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		repo.Close()
		_, _ = admin.Exec(ctx, "DROP DATABASE "+name+" WITH (FORCE)")
		_ = admin.Close(ctx)
	})
	for range 2 { // a second run must be a no-op
		if err := repo.Migrate(ctx); err != nil {
			t.Fatal(err)
		}
	}
	return repo
}

func (e *testEnv) token(t *testing.T, edit func(*jwt.Claims)) string {
	t.Helper()
	c := jwt.Claims{Issuer: issuer, Audience: jwt.Audience{audience}, Subject: "alice", Expiry: jwt.NewNumericDate(time.Now().Add(time.Hour))}
	if edit != nil {
		edit(&c)
	}
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: jose.JSONWebKey{Key: e.signingKey, KeyID: e.kid}}, (&jose.SignerOptions{}).WithType("at+jwt"))
	if err != nil {
		t.Fatal(err)
	}
	raw, err := jwt.Signed(signer).Claims(c).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (e *testEnv) as(t *testing.T, subject string) string {
	return e.token(t, func(c *jwt.Claims) { c.Subject = subject })
}

func (e *testEnv) do(t *testing.T, token, method, path string, body any) *httptest.ResponseRecorder {
	t.Helper()
	var reader io.Reader
	switch value := body.(type) {
	case nil:
	case []byte:
		reader = bytes.NewReader(value)
	default:
		raw, err := json.Marshal(value)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}
	request := httptest.NewRequest(method, path, reader)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	recorder := httptest.NewRecorder()
	e.handler.ServeHTTP(recorder, request)
	return recorder
}

func expect(t *testing.T, response *httptest.ResponseRecorder, status int) {
	t.Helper()
	if response.Code != status {
		t.Fatalf("status = %d, want %d: %s", response.Code, status, response.Body.String())
	}
}

func decode[T any](t *testing.T, response *httptest.ResponseRecorder) T {
	t.Helper()
	var value T
	if err := json.Unmarshal(response.Body.Bytes(), &value); err != nil {
		t.Fatalf("decode %q: %v", response.Body.String(), err)
	}
	return value
}

func sealed(size int) []byte {
	value := make([]byte, size)
	_, _ = rand.Read(value)
	value[0] = 0x01
	return value
}

func recordBody(kid, base int, sealedBytes []byte) map[string]any {
	return map[string]any{"kid": kid, "baseRevision": base, "sealed": base64.StdEncoding.EncodeToString(sealedBytes)}
}

const (
	id1 = "6f1d3c1e-8a52-4c1b-9b7e-2f4f1e0a1b01"
	id2 = "6f1d3c1e-8a52-4c1b-9b7e-2f4f1e0a1b02"
	id3 = "6F1D3C1E-8A52-4C1B-9B7E-2F4F1E0A1B03" // upper case is stored lower case
)

func TestAuthRejectsBadTokens(t *testing.T) {
	env := newEnv(t)
	cases := map[string]string{
		"missing":      "",
		"garbage":      "not-a-jwt",
		"bad audience": env.token(t, func(c *jwt.Claims) { c.Audience = jwt.Audience{"https://split.ghenti.com"} }),
		"expired":      env.token(t, func(c *jwt.Claims) { c.Expiry = jwt.NewNumericDate(time.Now().Add(-time.Hour)) }),
		"wrong issuer": env.token(t, func(c *jwt.Claims) { c.Issuer = "https://evil.test/api/auth" }),
		"unsafe sub":   env.as(t, "../bob"),
	}
	for name, token := range cases {
		response := env.do(t, token, "GET", "/v1/account", nil)
		if response.Code != http.StatusUnauthorized || decode[map[string]string](t, response)["error"] != "unauthorized" {
			t.Errorf("%s: status %d %s", name, response.Code, response.Body.String())
		}
	}
	expect(t, env.do(t, env.as(t, "alice"), "GET", "/v1/account", nil), http.StatusOK)
	// Glide's real tokens (typ at+jwt) carry both this API and userinfo in an aud array.
	expect(t, env.do(t, env.token(t, func(c *jwt.Claims) {
		c.Audience = jwt.Audience{audience, "https://auth.test/api/auth/oauth2/userinfo"}
	}), "GET", "/v1/account", nil), http.StatusOK)
	expect(t, env.do(t, env.token(t, func(c *jwt.Claims) {
		c.Audience = jwt.Audience{"https://split.ghenti.com", "https://auth.test/api/auth/oauth2/userinfo"}
	}), "GET", "/v1/account", nil), http.StatusUnauthorized)

	// A token signed with a key the cached set lacks makes the verifier refetch the JWKS.
	env.rotate()
	expect(t, env.do(t, env.as(t, "alice"), "GET", "/v1/account", nil), http.StatusOK)
}

func TestRecordsRevisionsTombstonesAndPaging(t *testing.T) {
	env := newEnv(t)
	alice := env.as(t, "alice")

	created := decode[repository.Record](t, env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(1, 0, sealed(64))))
	if created.ID != id1 || created.Revision != 1 || created.Deleted || created.Kid != 1 || len(created.Sealed) != 64 {
		t.Fatalf("created = %+v", created)
	}
	updated := decode[repository.Record](t, env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(2, 1, sealed(80))))
	if updated.Revision != 2 || updated.Seq <= created.Seq || updated.Kid != 2 {
		t.Fatalf("updated = %+v", updated)
	}

	stale := env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(2, 1, sealed(90)))
	expect(t, stale, http.StatusConflict)
	if current := decode[repository.Record](t, stale); current.Revision != 2 || !bytes.Equal(current.Sealed, updated.Sealed) {
		t.Fatalf("409 body = %+v, want the stored revision 2", current)
	}
	// Creating with base 0 over an existing record is stale too.
	expect(t, env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(2, 0, sealed(90))), http.StatusConflict)
	expect(t, env.do(t, alice, "PUT", "/v1/records/"+id2, recordBody(1, 3, sealed(64))), http.StatusNotFound)

	expect(t, env.do(t, alice, "DELETE", "/v1/records/"+id1, nil), http.StatusNoContent)
	expect(t, env.do(t, alice, "DELETE", "/v1/records/"+id1, nil), http.StatusNoContent)
	expect(t, env.do(t, alice, "DELETE", "/v1/records/"+id2, nil), http.StatusNotFound)
	list := env.do(t, alice, "GET", "/v1/records?after=0", nil)
	if !strings.Contains(list.Body.String(), `"sealed":null`) {
		t.Fatalf("tombstone should carry sealed null: %s", list.Body.String())
	}
	page := decode[struct {
		Items []repository.Record
		Next  *int64
	}](t, list)
	if len(page.Items) != 1 || !page.Items[0].Deleted || page.Items[0].Revision != 3 || page.Next != nil {
		t.Fatalf("after delete = %+v", page)
	}
	// Re-creating from the tombstone's revision brings it back.
	revived := decode[repository.Record](t, env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(2, 3, sealed(64))))
	if revived.Deleted || revived.Revision != 4 {
		t.Fatalf("revived = %+v", revived)
	}

	created3 := decode[repository.Record](t, env.do(t, alice, "PUT", "/v1/records/"+id3, recordBody(1, 0, sealed(64))))
	if created3.ID != strings.ToLower(id3) {
		t.Fatalf("id = %s", created3.ID)
	}
	for i := range 5 {
		expect(t, env.do(t, alice, "PUT", fmt.Sprintf("/v1/records/00000000-0000-4000-8000-%012d", i), recordBody(1, 0, sealed(40))), http.StatusOK)
	}
	expect(t, env.do(t, env.as(t, "bob"), "PUT", "/v1/records/"+id2, recordBody(1, 0, sealed(40))), http.StatusOK)

	var seen []repository.Record
	after := int64(0)
	for pages := 0; ; pages++ {
		page := decode[struct {
			Items []repository.Record
			Next  *int64
		}](t, env.do(t, alice, "GET", fmt.Sprintf("/v1/records?after=%d&limit=3", after), nil))
		seen = append(seen, page.Items...)
		if page.Next == nil {
			break
		}
		if pages > 5 {
			t.Fatal("paging does not end")
		}
		after = *page.Next
	}
	if len(seen) != 7 {
		t.Fatalf("paged %d records, want alice's 7", len(seen))
	}
	for i := 1; i < len(seen); i++ {
		if seen[i].Seq <= seen[i-1].Seq {
			t.Fatalf("not in seq order: %+v", seen)
		}
	}
	account := decode[repository.Account](t, env.do(t, alice, "GET", "/v1/account", nil))
	if account.Records != 7 || account.KeyKid != 2 || account.Training.Enabled {
		t.Fatalf("account = %+v", account)
	}
}

func TestShapeAndSizeLimits(t *testing.T) {
	env := newEnv(t)
	alice := env.as(t, "alice")
	put := func(body any) *httptest.ResponseRecorder { return env.do(t, alice, "PUT", "/v1/records/"+id1, body) }

	expect(t, put(map[string]any{"kid": 1, "baseRevision": 0, "sealed": "!!not base64"}), http.StatusBadRequest)
	wrongVersion := sealed(64)
	wrongVersion[0] = 0x02
	expect(t, put(recordBody(1, 0, wrongVersion)), http.StatusBadRequest)
	expect(t, put(recordBody(1, 0, sealed(28))), http.StatusBadRequest)
	expect(t, put(recordBody(0, 0, sealed(64))), http.StatusBadRequest)
	expect(t, put(map[string]any{"kid": 1, "sealed": base64.StdEncoding.EncodeToString(sealed(64))}), http.StatusBadRequest)
	expect(t, put(recordBody(1, 0, sealed(29))), http.StatusOK)
	expect(t, put(recordBody(1, 1, sealed(256<<10))), http.StatusOK)
	tooBig := put(recordBody(1, 2, sealed(256<<10+1)))
	expect(t, tooBig, http.StatusRequestEntityTooLarge)
	if decode[map[string]string](t, tooBig)["error"] != "too_large" {
		t.Fatal(tooBig.Body.String())
	}
	expect(t, env.do(t, alice, "PUT", "/v1/records/not-a-uuid", recordBody(1, 0, sealed(64))), http.StatusBadRequest)
	expect(t, env.do(t, alice, "GET", "/v1/records", nil), http.StatusBadRequest)
	expect(t, env.do(t, alice, "GET", "/v1/records?after=0&limit=501", nil), http.StatusBadRequest)
	expect(t, env.do(t, alice, "GET", "/v1/nowhere", nil), http.StatusNotFound)

	// Declared too large: refused before the body is read.
	request := httptest.NewRequest("PUT", "/v1/audio/"+id1, strings.NewReader("x"))
	request.Header.Set("Authorization", "Bearer "+alice)
	request.ContentLength = 8<<20 + 1
	recorder := httptest.NewRecorder()
	env.handler.ServeHTTP(recorder, request)
	expect(t, recorder, http.StatusRequestEntityTooLarge)
	// Undeclared length (chunked): cut off at the limit.
	request = httptest.NewRequest("PUT", "/v1/audio/"+id1, bytes.NewReader(sealed(8<<20+1)))
	request.Header.Set("Authorization", "Bearer "+alice)
	request.ContentLength = -1
	recorder = httptest.NewRecorder()
	env.handler.ServeHTTP(recorder, request)
	expect(t, recorder, http.StatusRequestEntityTooLarge)
	expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id1, sealed(8<<20)), http.StatusNoContent)
	if len(env.s3.keys("glide/alice/audio/")) != 1 {
		t.Fatal("8 MiB audio was not stored")
	}
}

func TestAudioFollowsItsRecord(t *testing.T) {
	env := newEnv(t)
	alice := env.as(t, "alice")
	audio := sealed(1000)

	expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id1, audio), http.StatusNotFound)
	created := decode[repository.Record](t, env.do(t, alice, "PUT", "/v1/records/"+id1, recordBody(1, 0, sealed(64))))
	expect(t, env.do(t, alice, "GET", "/v1/audio/"+id1, nil), http.StatusNotFound)
	expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id1, []byte{0x01, 0x02}), http.StatusBadRequest)
	expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id1, audio), http.StatusNoContent)

	// The audio change reaches other devices through the cursor.
	page := decode[struct{ Items []repository.Record }](t, env.do(t, alice, "GET", fmt.Sprintf("/v1/records?after=%d", created.Seq), nil))
	if len(page.Items) != 1 || !page.Items[0].HasAudio || page.Items[0].Revision != 1 {
		t.Fatalf("after audio = %+v", page.Items)
	}
	got := env.do(t, alice, "GET", "/v1/audio/"+id1, nil)
	expect(t, got, http.StatusOK)
	if !bytes.Equal(got.Body.Bytes(), audio) || got.Header().Get("Content-Type") != "application/octet-stream" {
		t.Fatal("audio round trip changed the bytes")
	}
	if account := decode[repository.Account](t, env.do(t, alice, "GET", "/v1/account", nil)); account.AudioBytes != 1000 {
		t.Fatalf("audioBytes = %d", account.AudioBytes)
	}
	expect(t, env.do(t, env.as(t, "bob"), "GET", "/v1/audio/"+id1, nil), http.StatusNotFound)

	expect(t, env.do(t, alice, "DELETE", "/v1/records/"+id1, nil), http.StatusNoContent)
	if keys := env.s3.keys("glide/alice/"); len(keys) != 0 {
		t.Fatalf("audio left after delete: %v", keys)
	}
	expect(t, env.do(t, alice, "GET", "/v1/audio/"+id1, nil), http.StatusNotFound)
	expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id1, audio), http.StatusNotFound)
}

func TestDeleteAllSynced(t *testing.T) {
	env := newEnv(t)
	alice, bob := env.as(t, "alice"), env.as(t, "bob")
	for _, id := range []string{id1, id2} {
		expect(t, env.do(t, alice, "PUT", "/v1/records/"+id, recordBody(1, 0, sealed(64))), http.StatusOK)
		expect(t, env.do(t, alice, "PUT", "/v1/audio/"+id, sealed(100)), http.StatusNoContent)
	}
	expect(t, env.do(t, bob, "PUT", "/v1/records/"+id1, recordBody(1, 0, sealed(64))), http.StatusOK)
	expect(t, env.do(t, bob, "PUT", "/v1/audio/"+id1, sealed(100)), http.StatusNoContent)
	env.s3.objects["glide/alice/audio/orphan"] = []byte{1} // left by an earlier failed delete

	expect(t, env.do(t, alice, "DELETE", "/v1/records", nil), http.StatusNoContent)
	if keys := env.s3.keys("glide/alice/"); len(keys) != 0 {
		t.Fatalf("objects left: %v", keys)
	}
	page := decode[struct{ Items []repository.Record }](t, env.do(t, alice, "GET", "/v1/records?after=0", nil))
	if len(page.Items) != 0 {
		t.Fatalf("records left: %+v", page.Items)
	}
	if account := decode[repository.Account](t, env.do(t, alice, "GET", "/v1/account", nil)); account.Records != 0 || account.AudioBytes != 0 {
		t.Fatalf("account = %+v", account)
	}
	if len(env.s3.keys("glide/bob/")) != 1 || decode[repository.Account](t, env.do(t, bob, "GET", "/v1/account", nil)).Records != 1 {
		t.Fatal("another user's data was touched")
	}
}

func TestTrainingConsentGatesItems(t *testing.T) {
	env := newEnv(t)
	alice, bob := env.as(t, "alice"), env.as(t, "bob")
	wrapped := sealed(512)
	item := func(sealedBytes []byte) []byte { return append(append([]byte{}, wrapped...), sealedBytes...) }
	put := func(token, id string, body []byte) *httptest.ResponseRecorder {
		return env.do(t, token, "PUT", "/v1/training/items/"+id+"?keyVersion=2", body)
	}

	forbidden := put(alice, id1, item(sealed(64)))
	expect(t, forbidden, http.StatusForbidden)
	if decode[map[string]string](t, forbidden)["error"] != "forbidden" {
		t.Fatal(forbidden.Body.String())
	}

	on := decode[repository.Consent](t, env.do(t, alice, "PUT", "/v1/training/consent", map[string]bool{"enabled": true}))
	if !on.Enabled || on.Since == nil {
		t.Fatalf("consent = %+v", on)
	}
	again := decode[repository.Consent](t, env.do(t, alice, "PUT", "/v1/training/consent", map[string]bool{"enabled": true}))
	if !again.Since.Equal(*on.Since) {
		t.Fatal("turning consent on again moved since")
	}

	expect(t, env.do(t, alice, "PUT", "/v1/training/items/"+id1, item(sealed(64))), http.StatusBadRequest) // no keyVersion
	expect(t, put(alice, id1, sealed(100)), http.StatusBadRequest)                                            // no wrapped key
	expect(t, put(alice, id1, item(sealed(64))), http.StatusNoContent)
	expect(t, put(alice, id1, item(sealed(70))), http.StatusNoContent)
	expect(t, put(alice, id2, item(sealed(8<<20))), http.StatusNoContent)
	expect(t, put(alice, id3, item(sealed(8<<20+1))), http.StatusRequestEntityTooLarge)
	// Stored as sent, with no account in the path.
	key := "training/" + id1
	if !bytes.Equal(env.s3.objects[key][:512], wrapped) || len(env.s3.objects[key]) != 512+70 || env.s3.meta[key].Get("X-Amz-Meta-Key-Version") != "2" {
		t.Fatalf("stored item: %d bytes, meta %v", len(env.s3.objects[key]), env.s3.meta[key])
	}
	if keys := env.s3.keys("training/alice"); len(keys) != 0 {
		t.Fatalf("account in object keys: %v", keys)
	}
	if account := decode[repository.Account](t, env.do(t, alice, "GET", "/v1/account", nil)); account.Training.Items != 2 {
		t.Fatalf("training = %+v", account.Training)
	}

	// An id belongs to whoever shared it first: another account can neither replace nor delete it.
	expect(t, env.do(t, bob, "PUT", "/v1/training/consent", map[string]bool{"enabled": true}), http.StatusOK)
	expect(t, put(bob, id1, item(sealed(80))), http.StatusForbidden)
	expect(t, env.do(t, bob, "DELETE", "/v1/training/items/"+id1, nil), http.StatusNoContent)
	if len(env.s3.objects[key]) != 512+70 {
		t.Fatal("another account changed the item")
	}

	expect(t, env.do(t, alice, "DELETE", "/v1/training/items/"+id1, nil), http.StatusNoContent)
	if _, ok := env.s3.objects[key]; ok {
		t.Fatal("deleted item still stored")
	}
	expect(t, put(alice, id1, item(sealed(64))), http.StatusNoContent)
	expect(t, put(bob, id3, item(sealed(64))), http.StatusNoContent)

	off := decode[repository.Consent](t, env.do(t, alice, "PUT", "/v1/training/consent", map[string]bool{"enabled": false}))
	if off.Enabled || off.Since != nil || off.Items != 0 {
		t.Fatalf("consent off = %+v", off)
	}
	if keys := env.s3.keys("training/"); len(keys) != 1 || keys[0] != "training/"+strings.ToLower(id3) {
		t.Fatalf("after alice turned sharing off: %v", keys)
	}
	expect(t, put(alice, id1, item(sealed(64))), http.StatusForbidden)
	expect(t, env.do(t, alice, "PUT", "/v1/training/consent", map[string]any{}), http.StatusBadRequest)
}

func TestTrainingKeyIsCached(t *testing.T) {
	env := newEnv(t)
	alice := env.as(t, "alice")
	for range 2 {
		key := decode[publicKey](t, env.do(t, alice, "GET", "/v1/training/key", nil))
		if key.Version != 2 || !strings.Contains(key.PublicKeyPEM, "NEW") {
			t.Fatalf("key = %+v", key)
		}
	}
	if calls := env.transitCalls.Load(); calls != 1 {
		t.Fatalf("OpenBao read %d times, want 1", calls)
	}
}

func TestPublicPages(t *testing.T) {
	env := newEnv(t)
	aasa := env.do(t, "", "GET", "/.well-known/apple-app-site-association", nil)
	expect(t, aasa, http.StatusOK)
	if aasa.Header().Get("Content-Type") != "application/json" || aasa.Body.String() != `{"webcredentials":{"apps":["KSH6P6Y39N.com.ghentilabs.glide"]}}` {
		t.Fatalf("AASA = %q %q", aasa.Header().Get("Content-Type"), aasa.Body.String())
	}
	for _, path := range []string{"/auth/callback?code=secret-code&state=s", "/keys/callback"} {
		page := env.do(t, "", "GET", path, nil)
		expect(t, page, http.StatusOK)
		if page.Header().Get("Cache-Control") != "no-store" || page.Header().Get("Referrer-Policy") != "no-referrer" ||
			!strings.HasPrefix(page.Header().Get("Content-Type"), "text/html") || !strings.Contains(page.Body.String(), "Return to Glide") ||
			strings.Contains(page.Body.String(), "secret-code") {
			t.Fatalf("%s = %v %s", path, page.Header(), page.Body.String())
		}
	}
	expect(t, env.do(t, "", "GET", "/health", nil), http.StatusOK)
}
