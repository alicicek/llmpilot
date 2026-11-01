package analytics

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
}

func assistantLine(model, day, msgID, reqID string, in, out int64) string {
	return fmt.Sprintf(`{"type":"assistant","timestamp":"%sT10:00:00.000Z","requestId":"%s","message":{"id":"%s","model":"%s","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":7,"cache_read_input_tokens":11}}}`,
		day, reqID, msgID, model, in, out)
}

func TestScanAggregatesAndSkipsJunk(t *testing.T) {
	cfg := t.TempDir()
	transcript := assistantLine("claude-fable-5", "2026-07-01", "msg_1", "req_1", 100, 10) + "\n" +
		assistantLine("claude-fable-5", "2026-07-01", "msg_1", "req_1", 100, 10) + "\n" + // dup: same id+request
		assistantLine("claude-fable-5", "2026-07-02", "msg_2", "req_2", 50, 5) + "\n" +
		assistantLine("claude-sonnet-5", "2026-07-01", "msg_3", "req_3", 30, 3) + "\n" +
		`{"type":"user","timestamp":"2026-07-01T10:00:01.000Z","message":{"role":"user","content":"hi assistant"}}` + "\n" +
		`{"type":"system","subtype":"whatever"}` + "\n" +
		`{"type":"file-history-snapshot","futureField":{"deep":true}}` + "\n" +
		`not json at all` + "\n" +
		`{"type":"assistant","message":{"model":"claude-fable-5"}}` + "\n" // no usage: skipped
	writeFile(t, filepath.Join(cfg, "projects", "proj-x", "s1.jsonl"), transcript)

	agg, err := Scan(cfg, "")
	if err != nil {
		t.Fatal(err)
	}
	if agg.FilesTotal != 1 || agg.FilesParsed != 1 {
		t.Fatalf("counts: %+v", agg)
	}
	// "proj-x" decodes (dash-as-separator, v1 heuristic) to basename "x".
	want := []Cell{
		{Project: "x", Model: "claude-fable-5", Day: "2026-07-01", Messages: 1, Tokens: Tokens{Input: 100, Output: 10, CacheCreation: 7, CacheRead: 11}},
		{Project: "x", Model: "claude-fable-5", Day: "2026-07-02", Messages: 1, Tokens: Tokens{Input: 50, Output: 5, CacheCreation: 7, CacheRead: 11}},
		{Project: "x", Model: "claude-sonnet-5", Day: "2026-07-01", Messages: 1, Tokens: Tokens{Input: 30, Output: 3, CacheCreation: 7, CacheRead: 11}},
	}
	if len(agg.Cells) != len(want) {
		t.Fatalf("cells = %+v", agg.Cells)
	}
	for i := range want {
		if agg.Cells[i] != want[i] {
			t.Fatalf("cell[%d] = %+v, want %+v", i, agg.Cells[i], want[i])
		}
	}

	totals := agg.TotalsByModel()
	if len(totals) != 2 || totals[0].Model != "claude-fable-5" || totals[0].Messages != 2 ||
		totals[0].Tokens.Input != 150 {
		t.Fatalf("totals = %+v", totals)
	}
}

func TestScanMissingProjectsDirIsEmpty(t *testing.T) {
	agg, err := Scan(t.TempDir(), "")
	if err != nil {
		t.Fatal(err)
	}
	if agg.FilesTotal != 0 || len(agg.Cells) != 0 {
		t.Fatalf("want empty aggregate, got %+v", agg)
	}
}

func TestScanCacheReuseAndInvalidation(t *testing.T) {
	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	const files = 20
	for i := range files {
		writeFile(t,
			filepath.Join(cfg, "projects", "p", fmt.Sprintf("s%02d.jsonl", i)),
			assistantLine("claude-fable-5", "2026-07-01", fmt.Sprintf("m%d", i), fmt.Sprintf("r%d", i), 10, 1)+"\n")
	}

	first, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if first.FilesParsed != files || first.FilesReused != 0 {
		t.Fatalf("first scan: %+v", first)
	}

	second, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if second.FilesParsed != 0 || second.FilesReused != files {
		t.Fatalf("second scan should be all cache hits: %+v", second)
	}
	if len(second.Cells) != 1 || second.Cells[0].Messages != files {
		t.Fatalf("cached aggregate wrong: %+v", second.Cells)
	}

	// Touch one file with new content + explicit mtime bump.
	target := filepath.Join(cfg, "projects", "p", "s00.jsonl")
	writeFile(t, target,
		assistantLine("claude-fable-5", "2026-07-01", "m0", "r0", 10, 1)+"\n"+
			assistantLine("claude-opus-4-8", "2026-07-03", "mx", "rx", 5, 2)+"\n")
	if err := os.Chtimes(target, time.Now(), time.Now().Add(3*time.Second)); err != nil {
		t.Fatal(err)
	}

	third, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if third.FilesParsed != 1 || third.FilesReused != files-1 {
		t.Fatalf("third scan should reparse exactly the touched file: %+v", third)
	}
	totals := third.TotalsByModel()
	if len(totals) != 2 {
		t.Fatalf("totals after change: %+v", totals)
	}

	// Delete a file: it must drop out of the aggregate and the cache.
	if err := os.Remove(filepath.Join(cfg, "projects", "p", "s01.jsonl")); err != nil {
		t.Fatal(err)
	}
	fourth, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if fourth.FilesTotal != files-1 {
		t.Fatalf("deleted file still counted: %+v", fourth)
	}
}

func TestScanCorruptCacheSelfHeals(t *testing.T) {
	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	writeFile(t, filepath.Join(cfg, "projects", "p", "s.jsonl"),
		assistantLine("claude-fable-5", "2026-07-01", "m", "r", 1, 1)+"\n")
	writeFile(t, cachePath, `{"version": 999, "files": "garbage`)

	agg, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if agg.FilesParsed != 1 {
		t.Fatalf("corrupt cache should force re-parse: %+v", agg)
	}
}

// TestScanPerfThousandFiles is the cache perf gate: ~1k synthetic
// files, warm scan must reuse every one of them without re-parsing.
func TestScanPerfThousandFiles(t *testing.T) {
	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	const files = 1000
	for i := range files {
		var b []byte
		for j := range 10 {
			b = append(b, assistantLine("claude-fable-5", "2026-07-01",
				fmt.Sprintf("m%d-%d", i, j), fmt.Sprintf("r%d-%d", i, j), 100, 10)...)
			b = append(b, '\n')
		}
		writeFile(t, filepath.Join(cfg, "projects", fmt.Sprintf("p%02d", i%50), fmt.Sprintf("s%04d.jsonl", i)), string(b))
	}

	start := time.Now()
	cold, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	coldD := time.Since(start)
	if cold.FilesParsed != files {
		t.Fatalf("cold scan: %+v", cold)
	}

	start = time.Now()
	warm, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	warmD := time.Since(start)
	if warm.FilesParsed != 0 || warm.FilesReused != files {
		t.Fatalf("warm scan must skip every unchanged file: parsed=%d reused=%d",
			warm.FilesParsed, warm.FilesReused)
	}
	// Files are spread across 50 project dirs (p00..p49), so the aggregate is
	// 50 cells (one per project) rather than one — sum across all of them.
	if len(warm.Cells) != 50 {
		t.Fatalf("want 50 project cells, got %d: %+v", len(warm.Cells), warm.Cells)
	}
	var totalMsgs int64
	for _, c := range warm.Cells {
		totalMsgs += c.Messages
	}
	if totalMsgs != int64(files*10) {
		t.Fatalf("aggregate lost messages: total=%d want=%d", totalMsgs, files*10)
	}
	t.Logf("cold=%v warm=%v (%d files, %d lines)", coldD, warmD, files, files*10)
}

func TestProjectFromDirName(t *testing.T) {
	cases := []struct{ name, want string }{
		{"-Users-alice-dev-llmpilot", "llmpilot"},
		// only the FINAL path segment needs to be dash-free to recover
		// exactly — earlier dashed segments (here "tale-mode") don't matter.
		{"-private-tmp-tale-mode-91a2-scratchpad", "scratchpad"},
		{"proj-x", "x"},
		{"noslashes", "noslashes"},
		{"", "other"},
		{"-", "other"},
	}
	for _, c := range cases {
		if got := projectFromDirName(c.name); got != c.want {
			t.Errorf("projectFromDirName(%q) = %q, want %q", c.name, got, c.want)
		}
	}
}

// TestScanHourWeekdayBucketsAndCaches proves entries land in the right
// (weekday, hour) slot of the burn heatmap, keyed by day for range
// filtering, and that a cache-hit rescan still returns the same grid without
// re-parsing.
func TestScanHourWeekdayBucketsAndCaches(t *testing.T) {
	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")

	const ts1 = "2026-07-06T09:15:00.000Z" // day 1
	const ts2 = "2026-07-07T02:10:00.000Z" // day 2
	line := func(ts, msgID, reqID string, in, out int64) string {
		return fmt.Sprintf(`{"type":"assistant","timestamp":"%s","requestId":"%s","message":{"id":"%s","model":"claude-fable-5","usage":{"input_tokens":%d,"output_tokens":%d,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}`,
			ts, reqID, msgID, in, out)
	}
	transcript := line(ts1, "m1", "r1", 100, 20) + "\n" + line(ts2, "m2", "r2", 50, 5) + "\n"
	writeFile(t, filepath.Join(cfg, "projects", "p", "s.jsonl"), transcript)

	t1, err := time.Parse(time.RFC3339Nano, ts1)
	if err != nil {
		t.Fatal(err)
	}
	t2, err := time.Parse(time.RFC3339Nano, ts2)
	if err != nil {
		t.Fatal(err)
	}
	l1, l2 := t1.Local(), t2.Local()
	day1, day2 := ts1[:10], ts2[:10]

	check := func(t *testing.T, agg *Aggregate) {
		t.Helper()
		g1, ok := agg.DailyHourWeekday[day1]
		if !ok {
			t.Fatalf("no grid for day %s: %+v", day1, agg.DailyHourWeekday)
		}
		if g1[int(l1.Weekday())][l1.Hour()] != 120 {
			t.Fatalf("day1 slot [%v][%d] = %d, want 120", l1.Weekday(), l1.Hour(), g1[int(l1.Weekday())][l1.Hour()])
		}
		g2, ok := agg.DailyHourWeekday[day2]
		if !ok {
			t.Fatalf("no grid for day %s: %+v", day2, agg.DailyHourWeekday)
		}
		if g2[int(l2.Weekday())][l2.Hour()] != 55 {
			t.Fatalf("day2 slot [%v][%d] = %d, want 55", l2.Weekday(), l2.Hour(), g2[int(l2.Weekday())][l2.Hour()])
		}
	}

	first, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if first.FilesParsed != 1 {
		t.Fatalf("first scan should parse the file: %+v", first)
	}
	check(t, first)

	second, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	if second.FilesParsed != 0 || second.FilesReused != 1 {
		t.Fatalf("second scan should be a cache hit: parsed=%d reused=%d", second.FilesParsed, second.FilesReused)
	}
	check(t, second)
}

// TestProjectFromTranscriptCwd pins the Greptile round-2 P2: a dashed
// basename like "tale-mode" keeps its real name because the project label
// comes from the transcript's own cwd, not the lossy dir-name decode — the
// decode remains only the no-cwd fallback.
func TestProjectFromTranscriptCwd(t *testing.T) {
	cfg := t.TempDir()
	withCwd := `{"type":"summary","cwd":"/Users/x/dev/tale-mode"}
{"type":"assistant","timestamp":"2026-07-01T10:00:00Z","requestId":"r1","cwd":"/Users/x/dev/tale-mode","message":{"id":"m1","model":"claude-fable-5","usage":{"input_tokens":10,"output_tokens":5}}}
`
	// the CC dir encoding for /Users/x/dev/tale-mode — the old heuristic
	// read this back as project "mode"
	writeFile(t, filepath.Join(cfg, "projects", "-Users-x-dev-tale-mode", "s.jsonl"), withCwd)

	noCwd := `{"type":"assistant","timestamp":"2026-07-01T11:00:00Z","requestId":"r2","message":{"id":"m2","model":"claude-fable-5","usage":{"input_tokens":7,"output_tokens":3}}}
`
	writeFile(t, filepath.Join(cfg, "projects", "-Users-x-dev-plainproj", "s.jsonl"), noCwd)

	agg, err := Scan(cfg, filepath.Join(t.TempDir(), "cache.json"))
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, c := range agg.Cells {
		got[c.Project] = true
	}
	if !got["tale-mode"] {
		t.Errorf("dashed basename lost its name: %v", got)
	}
	if got["mode"] {
		t.Errorf("old lossy decode leaked through: %v", got)
	}
	if !got["plainproj"] {
		t.Errorf("no-cwd file must fall back to the dir-name decode: %v", got)
	}
}

// appendTo adds content to the end of path.
func appendTo(t *testing.T, path, content string) {
	t.Helper()
	f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.WriteString(content); err != nil {
		t.Fatal(err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}
}

// sameAggregate fails unless a and b hold the same cells and heatmap.
func sameAggregate(t *testing.T, label string, a, b *Aggregate) {
	t.Helper()
	if fmt.Sprint(a.Cells) != fmt.Sprint(b.Cells) {
		t.Fatalf("%s: cells differ\n got %v\nwant %v", label, a.Cells, b.Cells)
	}
	if fmt.Sprint(a.DailyHourWeekday) != fmt.Sprint(b.DailyHourWeekday) {
		t.Fatalf("%s: heatmap differs", label)
	}
}

// A live session's transcript only grows. Once read, a big file is read on
// from where the last read stopped, and the totals equal a fresh read of
// the whole file — a repeat of the last message straddling the boundary
// counts once, and a half-written last line waits until it is whole.
func TestScanAppendMatchesAWholeRead(t *testing.T) {
	old := appendMin
	appendMin = 1
	t.Cleanup(func() { appendMin = old })

	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	path := filepath.Join(cfg, "projects", "-Users-x-dev-proj", "s.jsonl")
	last := assistantLine("claude-fable-5", "2026-07-01", "m2", "r2", 20, 2)
	writeFile(t, path,
		`{"type":"user","cwd":"/Users/x/dev/proj","message":{"role":"user","content":"hi"}}`+"\n"+
			assistantLine("claude-fable-5", "2026-07-01", "m1", "r1", 10, 1)+"\n"+last+"\n")
	if _, err := Scan(cfg, cachePath); err != nil {
		t.Fatal(err)
	}

	half := assistantLine("claude-opus-5", "2026-07-03", "m4", "r4", 40, 4)
	appendTo(t, path, last+"\n"+ // the same message again: counts once
		assistantLine("claude-sonnet-5", "2026-07-02", "m3", "r3", 30, 3)+"\n"+
		half[:len(half)/2]) // still being written
	got, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	whole, err := Scan(cfg, "")
	if err != nil {
		t.Fatal(err)
	}
	sameAggregate(t, "after append", got, whole)

	appendTo(t, path, half[len(half)/2:]+"\n")
	got, err = Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	whole, err = Scan(cfg, "")
	if err != nil {
		t.Fatal(err)
	}
	sameAggregate(t, "after the half line completes", got, whole)
	if len(got.Cells) != 3 || got.Cells[0].Project != "proj" {
		t.Fatalf("cells = %+v", got.Cells)
	}
}

// The point of the append read: what was already read is not read again.
// A change far before the read offset (outside the edge the hash covers)
// is invisible to it — the old model stays — while the appended line is
// counted.
func TestScanAppendDoesNotReReadThePrefix(t *testing.T) {
	old := appendMin
	appendMin = 1
	t.Cleanup(func() { appendMin = old })

	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	path := filepath.Join(cfg, "projects", "p", "s.jsonl")
	content := assistantLine("claude-aaaa-5", "2026-07-01", "m0", "r0", 1, 1) + "\n"
	for i := 1; i < 60; i++ { // well past edgeBytes after the first line
		content += assistantLine("claude-fable-5", "2026-07-01", fmt.Sprintf("m%d", i), fmt.Sprintf("r%d", i), 1, 1) + "\n"
	}
	writeFile(t, path, content)
	if _, err := Scan(cfg, cachePath); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	copy(data[bytes.Index(data, []byte("claude-aaaa-5")):], "claude-bbbb-5") // same length, first line only
	writeFile(t, path, string(data))
	appendTo(t, path, assistantLine("claude-sonnet-5", "2026-07-02", "mx", "rx", 1, 1)+"\n")

	got, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	models := map[string]bool{}
	for _, c := range got.Cells {
		models[c.Model] = true
	}
	if !models["claude-aaaa-5"] || models["claude-bbbb-5"] || !models["claude-sonnet-5"] {
		t.Fatalf("models = %v: the prefix was re-read, or the append was missed", models)
	}
}

// A file rewritten rather than appended to — the bytes before the read
// offset changed — is read whole again.
func TestScanRewrittenFileIsReadWhole(t *testing.T) {
	old := appendMin
	appendMin = 1
	t.Cleanup(func() { appendMin = old })

	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	path := filepath.Join(cfg, "projects", "p", "s.jsonl")
	writeFile(t, path, assistantLine("claude-fable-5", "2026-07-01", "m1", "r1", 10, 1)+"\n")
	if _, err := Scan(cfg, cachePath); err != nil {
		t.Fatal(err)
	}
	writeFile(t, path,
		assistantLine("claude-opus-5", "2026-07-05", "n1", "s1", 99, 9)+"\n"+
			assistantLine("claude-opus-5", "2026-07-05", "n2", "s2", 1, 1)+"\n")
	got, err := Scan(cfg, cachePath)
	if err != nil {
		t.Fatal(err)
	}
	whole, err := Scan(cfg, "")
	if err != nil {
		t.Fatal(err)
	}
	sameAggregate(t, "after a rewrite", got, whole)
}

// Small files keep no append state: they re-read in milliseconds, and the
// cache stays the size it was.
func TestScanSmallFilesKeepNoAppendState(t *testing.T) {
	cfg := t.TempDir()
	cachePath := filepath.Join(t.TempDir(), "cache.json")
	writeFile(t, filepath.Join(cfg, "projects", "p", "s.jsonl"),
		assistantLine("claude-fable-5", "2026-07-01", "m1", "r1", 10, 1)+"\n")
	if _, err := Scan(cfg, cachePath); err != nil {
		t.Fatal(err)
	}
	for p, fe := range loadCache(cachePath).Files {
		if fe.Offset != 0 || fe.Edge != "" || len(fe.Tail) != 0 {
			t.Fatalf("%s kept append state: %+v", p, fe)
		}
	}
}
