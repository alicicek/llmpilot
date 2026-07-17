package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInstallIDGeneratesOncePersistsAndRegeneratesOnCorruption(t *testing.T) {
	dir := t.TempDir()
	s := At(dir)

	first, err := s.InstallID()
	if err != nil {
		t.Fatal(err)
	}
	if !installIDShape.MatchString(first) {
		t.Fatalf("install id %q is not a UUIDv4", first)
	}

	info, err := os.Stat(filepath.Join(dir, "install.id"))
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o600 {
		t.Fatalf("install.id mode = %o, want 600", perm)
	}

	second, err := s.InstallID()
	if err != nil {
		t.Fatal(err)
	}
	if second != first {
		t.Fatalf("install id changed across reads: %q then %q", first, second)
	}

	// Corruption yields a fresh id rather than an error: a new identity can
	// only narrow access (the stored entitlement stays bound to the old one).
	if err := os.WriteFile(filepath.Join(dir, "install.id"), []byte("not-a-uuid\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	third, err := s.InstallID()
	if err != nil {
		t.Fatal(err)
	}
	if third == first || !installIDShape.MatchString(third) {
		t.Fatalf("corrupt file produced %q (previous %q)", third, first)
	}
}
