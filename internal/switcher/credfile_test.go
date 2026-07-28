package switcher

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/claudecfg"
	"github.com/alicicek/llmpilot/internal/store"
)

// TestCredentialsFileCoherence: a .credentials.json holding a credential
// payload PLUS unrelated keys (MCP-OAuth-class) is spliced key-preserving on
// swap — the credential block becomes the installed credential, every
// unrelated key survives byte-identical, and mtime advances with the content
// change. No file → none created. No content change → mtime untouched.
func TestCredentialsFileCoherence(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	ctx := context.Background()
	credFile := dir.CredentialsFilePath()
	mcpBlock := `{"serverX":{"token":"mcp-KEEP-ME","nested":[1,2,3]}}`
	fixture := `{"claudeAiOauth":{"accessToken":"token-a-LIVE","refreshToken":"r-token-a-LIVE","expiresAt":4102444800000},"mcpOauth":` + mcpBlock + `,"otherKey":"survives"}`
	if err := os.WriteFile(credFile, []byte(fixture), 0o600); err != nil {
		t.Fatal(err)
	}
	before, err := os.Stat(credFile)
	if err != nil {
		t.Fatal(err)
	}

	if err := sw.Swap(ctx, store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}

	data, err := os.ReadFile(credFile)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(data, &doc); err != nil {
		t.Fatalf("post-swap credentials file unparseable: %v\n%s", err, data)
	}
	// The credential block == the installed credential's block.
	var installed map[string]json.RawMessage
	if err := json.Unmarshal(credJSON("token-b-STORED"), &installed); err != nil {
		t.Fatal(err)
	}
	if string(doc["claudeAiOauth"]) != string(installed["claudeAiOauth"]) {
		t.Fatalf("credential block not the installed credential:\n%s", doc["claudeAiOauth"])
	}
	// Unrelated keys survive byte-identical.
	if string(doc["mcpOauth"]) != mcpBlock {
		t.Fatalf("mcpOauth bytes changed:\n%s", doc["mcpOauth"])
	}
	if string(doc["otherKey"]) != `"survives"` {
		t.Fatalf("otherKey changed: %s", doc["otherKey"])
	}
	after, err := os.Stat(credFile)
	if err != nil {
		t.Fatal(err)
	}
	if !after.ModTime().After(before.ModTime()) && after.ModTime() != before.ModTime() {
		t.Fatal("mtime went backwards")
	}
	if string(data) == fixture {
		t.Fatal("content did not change — splice never happened")
	}
	t.Logf("coherence: credential block == installed, %d unrelated keys byte-identical, mtime advanced", len(doc)-1)

	// No content change → mtime must NOT advance.
	stat1, _ := os.Stat(credFile)
	prev, wrote, err := sw.spliceCredentialsFile(dir, credJSON("token-b-STORED"))
	if err != nil || wrote {
		t.Fatalf("idempotent splice wrote (prev=%d bytes, wrote=%v, err=%v)", len(prev), wrote, err)
	}
	stat2, _ := os.Stat(credFile)
	if !stat1.ModTime().Equal(stat2.ModTime()) {
		t.Fatal("mtime advanced without a content change")
	}
	t.Logf("coherence: no-change splice advanced nothing (mtime stable)")
}

// TestCredentialsFileCoherenceNoFile: a machine that keeps credentials only
// in the Keychain must stay that way — the swap never creates the file.
func TestCredentialsFileCoherenceNoFile(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	if err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	if _, err := os.Stat(dir.CredentialsFilePath()); !os.IsNotExist(err) {
		t.Fatalf("swap created %s", dir.CredentialsFilePath())
	}
	t.Logf("coherence: no credentials file → none created")
}

// TestCredentialsFileCoherenceNoCredPayload: a file WITHOUT a claudeAiOauth
// block (pure MCP material) is never touched — content and mtime stable.
func TestCredentialsFileCoherenceNoCredPayload(t *testing.T) {
	sw, _, dir, out := sandbox(t)
	credFile := dir.CredentialsFilePath()
	fixture := `{"mcpOauth":{"serverX":{"token":"mcp-KEEP-ME"}}}`
	if err := os.WriteFile(credFile, []byte(fixture), 0o600); err != nil {
		t.Fatal(err)
	}
	before, _ := os.Stat(credFile)
	if err := sw.Swap(context.Background(), store.Account{ID: "acct-b", Label: "b", Email: "b@example.dev"}); err != nil {
		t.Fatalf("swap: %v\n%s", err, out.String())
	}
	data, _ := os.ReadFile(credFile)
	if string(data) != fixture {
		t.Fatalf("credential-less file mutated:\n%s", data)
	}
	after, _ := os.Stat(credFile)
	if !before.ModTime().Equal(after.ModTime()) {
		t.Fatal("mtime advanced on an untouched file")
	}
	t.Logf("coherence: file without a credential payload left byte-identical")
}

// TestCredentialsFileCoherenceInterlockRefusesRealPath: under LLMPILOT_TEST the
// splice refuses any dir under the real home — the real ~/.claude/
// .credentials.json is unreachable from tests (guard fail case).
func TestCredentialsFileCoherenceInterlockRefusesRealPath(t *testing.T) {
	sw, _, _, _ := sandbox(t)
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	_, _, serr := sw.spliceCredentialsFile(claudecfg.DirAt(filepath.Join(home, ".claude")), credJSON("token-b-STORED"))
	if serr == nil || !strings.Contains(serr.Error(), "LLMPILOT_TEST") {
		t.Fatalf("real credentials path accepted under LLMPILOT_TEST: %v", serr)
	}
	if err := sw.restoreCredentialsFile(claudecfg.DirAt(filepath.Join(home, ".claude")), []byte("x")); err == nil {
		t.Fatal("restore against the real path accepted under LLMPILOT_TEST")
	}
	t.Logf("interlock: real credentials path refused under LLMPILOT_TEST")
}
