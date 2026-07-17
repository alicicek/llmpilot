package store

import (
	"crypto/rand"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

var installIDShape = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

// InstallID returns this machine's random install identity, generating and
// persisting it on first run. It is a privacy-respecting UUIDv4 — never a
// hardware fingerprint — and lives in a plain 0600 file so it stays on this
// Mac (unlike the synchronizable trial marker). Deleting or corrupting the
// file yields a fresh id, which can only NARROW access: the stored
// entitlement is bound to the old id and fails closed until an online
// re-activation.
func (s *Store) InstallID() (string, error) {
	path := filepath.Join(s.home, "install.id")
	if raw, err := os.ReadFile(path); err == nil {
		id := strings.TrimSpace(string(raw))
		if installIDShape.MatchString(id) {
			return id, nil
		}
	} else if !os.IsNotExist(err) {
		return "", fmt.Errorf("read install id: %w", err)
	}
	id, err := newUUIDv4()
	if err != nil {
		return "", err
	}
	if err := writeFileAtomic(path, []byte(id+"\n")); err != nil {
		return "", fmt.Errorf("persist install id: %w", err)
	}
	return id, nil
}

func newUUIDv4() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("generate install id: %w", err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]), nil
}

// writeFileAtomic mirrors pilotapi.WriteJSONAtomic's tempfile+rename shape
// for a raw (non-JSON) file: 0600 file, 0700 directory, no partial reads.
func writeFileAtomic(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}
