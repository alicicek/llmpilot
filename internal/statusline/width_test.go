package statusline

import (
	"os"
	"testing"
	"time"
)

func TestRecordWidth(t *testing.T) {
	home := t.TempDir()
	if _, ok := LastWidth(home); ok {
		t.Fatal("a fresh home has no width")
	}
	for _, junk := range []int{0, -3, 1001} {
		if err := RecordWidth(home, junk); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := LastWidth(home); ok {
		t.Fatal("junk widths must not be recorded")
	}
	if err := RecordWidth(home, 80); err != nil {
		t.Fatal(err)
	}
	if n, ok := LastWidth(home); !ok || n != 80 {
		t.Fatalf("LastWidth = %d, %v; want 80", n, ok)
	}

	// The same width again must not rewrite the file (it runs every refresh).
	old := time.Now().Add(-time.Hour)
	if err := os.Chtimes(widthPath(home), old, old); err != nil {
		t.Fatal(err)
	}
	if err := RecordWidth(home, 80); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(widthPath(home)); !fi.ModTime().Equal(old) {
		t.Error("an unchanged width rewrote the file")
	}
	if err := RecordWidth(home, 132); err != nil {
		t.Fatal(err)
	}
	if n, _ := LastWidth(home); n != 132 {
		t.Errorf("a resize must update the width, got %d", n)
	}
}
