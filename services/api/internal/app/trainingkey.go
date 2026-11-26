package app

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"sync"
	"time"
)

const trainingKeyTTL = 5 * time.Minute

type publicKey struct {
	Version      int    `json:"version"`
	PublicKeyPEM string `json:"publicKeyPem"`
}

// trainingKeys reads the public half of transit key glide-training through the
// OpenBao agent's local proxy, which adds the pod's token.
type trainingKeys struct {
	url     string
	client  *http.Client
	mu      sync.Mutex
	cached  publicKey
	fetched time.Time
}

func (k *trainingKeys) get(ctx context.Context) (publicKey, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.cached.Version > 0 && time.Since(k.fetched) < trainingKeyTTL {
		return k.cached, nil
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, k.url, nil)
	if err != nil {
		return publicKey{}, err
	}
	response, err := k.client.Do(request)
	if err != nil {
		return publicKey{}, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return publicKey{}, fmt.Errorf("read training key: OpenBao returned %d", response.StatusCode)
	}
	var body struct {
		Data struct {
			LatestVersion int `json:"latest_version"`
			Keys          map[string]struct {
				PublicKey string `json:"public_key"`
			} `json:"keys"`
		} `json:"data"`
	}
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		return publicKey{}, fmt.Errorf("read training key: %w", err)
	}
	pem := body.Data.Keys[strconv.Itoa(body.Data.LatestVersion)].PublicKey
	if body.Data.LatestVersion < 1 || pem == "" {
		return publicKey{}, fmt.Errorf("read training key: no public key for version %d", body.Data.LatestVersion)
	}
	k.cached, k.fetched = publicKey{Version: body.Data.LatestVersion, PublicKeyPEM: pem}, time.Now()
	return k.cached, nil
}
