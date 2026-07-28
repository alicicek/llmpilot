package switcher

// .credentials.json coherence: on macOS the Keychain is the primary store,
// but the file "may hold other credential material (e.g. MCP OAuth) or the
// full payload on other setups" (claudecfg.CredentialsFilePath). Claude Code
// re-reads it during OAuth-401 recovery (mtime-gated storage polling —
// tengu_oauth_401_recovered_from_disk, verified against the 2.1.220 binary,
// 2026-07-25), so a swap that leaves a stale claudeAiOauth block there hands
// a recovering live session the OUTGOING account's credential. The fix is a
// key-preserving content splice — NEVER a bare mtime touch (that would mark
// the stale payload fresh), NEVER a whole-file overwrite (that would delete
// the user's MCP tokens), and NEVER file creation (a machine that keeps
// credentials only in the Keychain must stay that way).

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/alicicek/llmpilot/internal/claudecfg"
)

// spliceCredentialsFile updates dir's .credentials.json claudeAiOauth block
// to targetCred's, preserving every other key's bytes, via atomic
// tempfile+rename (a content update is what advances mtime). Returns the
// file's prior bytes for rollback and whether a write happened. A missing
// file, a file without a credential payload, or an already-coherent file is
// a no-op — mtime never advances without a content change.
func (s *Switcher) spliceCredentialsFile(dir claudecfg.Dir, targetCred []byte) (prev []byte, wrote bool, err error) {
	path := dir.CredentialsFilePath()
	// Interlock parity with every other credential write: under LLMPILOT_TEST
	// the real home's credential file is unreachable (the swapTo entry check
	// covers the config file only).
	if err := assertSandboxDir(dir.Path()); err != nil {
		return nil, false, err
	}
	prev, err = os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil // never create the file
	}
	if err != nil {
		return nil, false, err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(prev, &doc); err != nil {
		// Not a JSON object — we cannot tell what it holds; leave it alone
		// rather than risk destroying non-credential material.
		s.logf("credentials file %s is not parseable JSON — left untouched", path)
		return prev, false, nil
	}
	if _, ok := doc["claudeAiOauth"]; !ok {
		return prev, false, nil // no credential payload here — nothing to cohere
	}
	var target map[string]json.RawMessage
	if err := json.Unmarshal(targetCred, &target); err != nil {
		return prev, false, fmt.Errorf("credentials splice: target credential is not a JSON object")
	}
	block, ok := target["claudeAiOauth"]
	if !ok {
		return prev, false, errors.New("credentials splice: target credential has no claudeAiOauth block")
	}
	doc["claudeAiOauth"] = block
	data, err := json.Marshal(doc)
	if err != nil {
		return prev, false, err
	}
	// Validate before installing — a corrupt credentials file breaks CC's
	// 401 recovery on setups that rely on it.
	var check map[string]json.RawMessage
	if err := json.Unmarshal(data, &check); err != nil {
		return prev, false, fmt.Errorf("credentials splice: refusing to write unparseable result: %w", err)
	}
	if bytes.Equal(bytes.TrimRight(prev, "\n"), data) {
		return prev, false, nil // already coherent — do not advance mtime
	}
	if err := atomicWriteFile(path, append(data, '\n'), 0o600); err != nil {
		return prev, false, err
	}
	s.logf("credentials file spliced: claudeAiOauth updated, %d other keys preserved", len(doc)-1)
	return prev, true, nil
}

// removeCredentialsFileBlock deletes ONLY the claudeAiOauth key from dir's
// .credentials.json, preserving every other key's bytes, via the same atomic
// tempfile+rename. It is the retirement half of the "Move into the fleet"
// migration: after the sign-in lives in llmpilot's backups, the source copy
// must not stay readable. The same three prohibitions as the splice apply —
// never create the file, never overwrite non-credential material, never
// touch mtime without a content change.
//
// removed reports whether a claudeAiOauth block was actually taken out. An
// absent file, a file with no such block, and an unparseable file are all
// (removed=false, err=nil): the caller VERIFIES what remains readable rather
// than trusting this return, so "we could not tell" degrades into the
// clone-suspect path instead of a false success.
func (s *Switcher) removeCredentialsFileBlock(dir claudecfg.Dir) (prev []byte, removed bool, err error) {
	path := dir.CredentialsFilePath()
	if err := assertSandboxDir(dir.Path()); err != nil {
		return nil, false, err
	}
	prev, err = os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, false, nil // never create the file
	}
	if err != nil {
		return nil, false, err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(prev, &doc); err != nil {
		s.logf("credentials file %s is not parseable JSON — left untouched", path)
		return prev, false, nil
	}
	if _, ok := doc["claudeAiOauth"]; !ok {
		return prev, false, nil // nothing of ours in here
	}
	delete(doc, "claudeAiOauth")
	data, err := json.Marshal(doc)
	if err != nil {
		return prev, false, err
	}
	var check map[string]json.RawMessage
	if err := json.Unmarshal(data, &check); err != nil {
		return prev, false, fmt.Errorf("credentials removal: refusing to write unparseable result: %w", err)
	}
	if err := atomicWriteFile(path, append(data, '\n'), 0o600); err != nil {
		return prev, false, err
	}
	s.logf("credentials file retired: claudeAiOauth removed, %d other keys preserved", len(doc))
	return prev, true, nil
}

// restoreCredentialsFile puts the prior bytes back after a later swap step
// failed — the rollback leg for spliceCredentialsFile.
func (s *Switcher) restoreCredentialsFile(dir claudecfg.Dir, prev []byte) error {
	if err := assertSandboxDir(dir.Path()); err != nil {
		return err
	}
	return atomicWriteFile(dir.CredentialsFilePath(), prev, 0o600)
}
