package daemon

// Install-scoped auth for the sensitive license routes. The loopback port is
// reachable by any local process, so reachability is not authority: revealing
// or mutating license state requires the per-run token the daemon writes
// beside the port file (0600). Presenting it proves same-user filesystem
// access to the llmpilot home — the same trust boundary as install.id and
// the Keychain item.

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"net/http"
	"path/filepath"
	"strings"
)

// TokenFilePath is where the daemon persists this run's auth token for its
// clients (`llmpilot open`, the menu bar) to read. 0600, removed on exit.
func TokenFilePath(home string) string { return filepath.Join(home, "daemon.token") }

// newAuthToken returns a fresh 32-byte random token, hex-encoded.
func newAuthToken() (string, error) {
	var b [32]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}

// requireAuth admits a request only when `Authorization: Bearer <token>`
// matches this run's token. An empty stored token never matches, so a daemon
// whose token generation failed refuses every guarded request. The 401
// carries a machine code the cockpit maps to honest copy.
func (d *Daemon) requireAuth(w http.ResponseWriter, r *http.Request) bool {
	presented := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	if d.authToken != "" && subtle.ConstantTimeCompare([]byte(presented), []byte(d.authToken)) == 1 {
		return true
	}
	writeJSON(w, http.StatusUnauthorized, map[string]string{
		"error": "this action needs the cockpit's session token — reopen it from the menu bar or run `llmpilot open`",
		"code":  "auth_required",
	})
	return false
}
