// Package analytics aggregates local Claude Code JSONL transcripts into
// per-model, per-day, per-project token totals (plus an hour-of-day ×
// weekday burn heatmap), with a per-file mtime cache so unchanged
// transcripts are never re-parsed.
//
// Schema receipts (sampled from real transcripts on 2026-07-08): assistant
// lines carry message.model, message.usage token counts, and the dedup pair
// message.id + requestId; timestamps are ISO-8601. The transcript schema has
// NO effort/reasoning field and NO cost field — those dimensions are
// deliberately not invented here (cost would need a price table). Unknown
// line types and fields are ignored defensively.
package analytics

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
)

// Tokens is a token-count total.
type Tokens struct {
	Input         int64 `json:"input"`
	Output        int64 `json:"output"`
	CacheCreation int64 `json:"cache_creation"`
	CacheRead     int64 `json:"cache_read"`
}

func (t *Tokens) add(u Tokens) {
	t.Input += u.Input
	t.Output += u.Output
	t.CacheCreation += u.CacheCreation
	t.CacheRead += u.CacheRead
}

// Cell is one aggregation cell: one model, one project, on one day (UTC).
type Cell struct {
	Project  string `json:"project"`
	Model    string `json:"model"`
	Day      string `json:"day"` // YYYY-MM-DD, "unknown" when a line has no timestamp
	Messages int64  `json:"messages"`
	Tokens   Tokens `json:"tokens"`
}

// HourWeekday is a burn-rate heatmap grid: rows are weekday (index 0 =
// Sunday, matching time.Weekday), columns are the local hour 0..23. Values
// are total tokens (input+output) whose transcript timestamp falls in that
// slot.
type HourWeekday [7][24]int64

func (h *HourWeekday) add(o HourWeekday) {
	for w := range h {
		for hr := range h[w] {
			h[w][hr] += o[w][hr]
		}
	}
}

// Aggregate is the result of one scan.
type Aggregate struct {
	Cells []Cell // sorted by model, then day, then project
	// DailyHourWeekday is the burn heatmap broken out by day (same UTC
	// YYYY-MM-DD key as Cell.Day) so a caller can filter to a date range
	// before collapsing to one 7×24 grid — the same discipline the day-range
	// filter already applies to Cells.
	DailyHourWeekday map[string]HourWeekday
	FilesTotal       int
	FilesParsed      int // cache misses: files (re)parsed this scan
	FilesReused      int // cache hits: files served from the mtime cache
}

// TotalsByModel rolls the cells up to per-model totals (Day and Project left
// empty), sorted by model.
func (a *Aggregate) TotalsByModel() []Cell {
	byModel := map[string]*Cell{}
	for _, c := range a.Cells {
		t, ok := byModel[c.Model]
		if !ok {
			t = &Cell{Model: c.Model}
			byModel[c.Model] = t
		}
		t.Messages += c.Messages
		t.Tokens.add(c.Tokens)
	}
	out := make([]Cell, 0, len(byModel))
	for _, c := range byModel {
		out = append(out, *c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Model < out[j].Model })
	return out
}

// cacheDoc is the on-disk per-file cache. Version bumps invalidate wholesale
// (a corrupt or stale-shape cache just re-parses everything once — never a
// crash).
type cacheDoc struct {
	Version int                  `json:"version"`
	Files   map[string]fileEntry `json:"files"`
}

type fileEntry struct {
	MTimeUnixNano int64  `json:"mtime_unix_nano"`
	Size          int64  `json:"size"`
	Cells         []Cell `json:"cells"`
	// DailyHourWeekday mirrors Aggregate.DailyHourWeekday for this one file —
	// carried in the cache so a cache-hit file still contributes to the
	// heatmap without being re-parsed.
	DailyHourWeekday map[string]HourWeekday `json:"daily_hour_weekday,omitempty"`
}

// cacheVersion 3: project now derives from the transcript's own cwd field
// (exact) instead of the lossy dir-name decode — cached cells carry the old
// labels, so the derivation change must invalidate (Greptile P2, 2026-07-11).
// cacheVersion 2: added Cell.Project and fileEntry.DailyHourWeekday. Bumping
// this forces every v1 cache to re-parse once, the same "corrupt cache"
// self-heal path already handles.
const cacheVersion = 3

// Scan walks configDir/projects/**/*.jsonl and returns the aggregate,
// reusing cachePath for files whose size+mtime are unchanged. A missing or
// corrupt cache self-heals (full re-parse), never errors.
//
// Perf note: this runs synchronously in the caller's request/goroutine (the
// daemon's GET /v1/analytics handler calls it directly, no global lock) —
// the first call after an upgrade or against a large ~/.claude/projects can
// take real wall time, but the per-file mtime cache makes every repeat scan
// fast (see TestScanPerfThousandFiles). Concurrent scans of the SAME cache
// file are not locked against each other: WriteJSONAtomic's tempfile+rename
// means a reader never sees a torn file, but two overlapping scans can each
// redo the same parse work and the last writer's cache wins — acceptable for
// a single-user local daemon, not safe to assume for a multi-writer setup.
func Scan(configDir, cachePath string) (*Aggregate, error) {
	cache := loadCache(cachePath)
	next := cacheDoc{Version: cacheVersion, Files: map[string]fileEntry{}}
	agg := &Aggregate{}

	root := filepath.Join(configDir, "projects")
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(d.Name(), ".jsonl") {
			return nil //nolint:nilerr // unreadable entries are skipped, not fatal
		}
		info, err := d.Info()
		if err != nil {
			return nil //nolint:nilerr // vanished mid-walk: skip
		}
		agg.FilesTotal++
		if prev, ok := cache.Files[p]; ok &&
			prev.MTimeUnixNano == info.ModTime().UnixNano() && prev.Size == info.Size() {
			next.Files[p] = prev
			agg.FilesReused++
			return nil
		}
		project := projectFromPath(root, p)
		cells, hw := parseFile(p, project)
		next.Files[p] = fileEntry{
			MTimeUnixNano:    info.ModTime().UnixNano(),
			Size:             info.Size(),
			Cells:            cells,
			DailyHourWeekday: hw,
		}
		agg.FilesParsed++
		return nil
	})
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	if cachePath != "" {
		// Cache carries token counts and timestamps only — never content.
		if err := store.WriteJSONAtomic(cachePath, next); err != nil {
			return nil, err
		}
	}

	byKey := map[Cell]*Cell{} // key: Cell with zero counts
	dailyHW := map[string]HourWeekday{}
	for _, fe := range next.Files {
		for _, c := range fe.Cells {
			k := Cell{Model: c.Model, Day: c.Day, Project: c.Project}
			t, ok := byKey[k]
			if !ok {
				t = &Cell{Model: c.Model, Day: c.Day, Project: c.Project}
				byKey[k] = t
			}
			t.Messages += c.Messages
			t.Tokens.add(c.Tokens)
		}
		for day, g := range fe.DailyHourWeekday {
			cur := dailyHW[day]
			cur.add(g)
			dailyHW[day] = cur
		}
	}
	for _, c := range byKey {
		agg.Cells = append(agg.Cells, *c)
	}
	sort.Slice(agg.Cells, func(i, j int) bool {
		if agg.Cells[i].Model != agg.Cells[j].Model {
			return agg.Cells[i].Model < agg.Cells[j].Model
		}
		if agg.Cells[i].Day != agg.Cells[j].Day {
			return agg.Cells[i].Day < agg.Cells[j].Day
		}
		return agg.Cells[i].Project < agg.Cells[j].Project
	})
	agg.DailyHourWeekday = dailyHW
	return agg, nil
}

func loadCache(path string) cacheDoc {
	empty := cacheDoc{Version: cacheVersion, Files: map[string]fileEntry{}}
	if path == "" {
		return empty
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return empty
	}
	var doc cacheDoc
	if json.Unmarshal(data, &doc) != nil || doc.Version != cacheVersion || doc.Files == nil {
		return empty
	}
	return doc
}

// projectFromPath derives the project label for a transcript file: the
// first path component under root (the raw CC-encoded project dir name),
// decoded to a project label. Falls back to "other" for anything outside
// root or with no usable component.
func projectFromPath(root, filePath string) string {
	rel, err := filepath.Rel(root, filePath)
	if err != nil {
		return "other"
	}
	rel = filepath.ToSlash(rel)
	first, _, _ := strings.Cut(rel, "/")
	if first == "" {
		return "other"
	}
	return projectFromDirName(first)
}

// projectFromDirName decodes a Claude Code project directory name into a
// project label. CC encodes a session's absolute cwd by replacing every "/"
// with "-" (verified live against ~/.claude/projects/ on 2026-07-10, e.g.
// cwd /Users/alice/dev/llmpilot → dir -Users-alice-dev-llmpilot). That
// encoding is lossy — a literal "-" inside a path component is
// indistinguishable from an encoded "/" — so this is a v1 heuristic: reverse
// the substitution wholesale and take the final path component. It recovers
// the true basename exactly whenever that basename itself contains no dash
// (the common case, and true regardless of dashes earlier in the path,
// since only the FINAL segment is read back out); a dashed basename (e.g.
// "tale-mode") over-splits into its own last dash-delimited word. Worktree
// directories are deliberately NOT merged back into their parent project —
// that needs real path knowledge this heuristic doesn't have.
// It is the FALLBACK only: parseFile prefers the transcript's own cwd field,
// which is exact ("tale-mode" stays "tale-mode" — Greptile P2, 2026-07-11);
// this decode covers files that carry no cwd line at all.
func projectFromDirName(name string) string {
	decoded := strings.ReplaceAll(name, "-", "/")
	base := path.Base(decoded)
	if base == "" || base == "." || base == "/" {
		return "other"
	}
	return base
}

// parseFile aggregates one transcript. Lines that are not assistant usage
// lines — user lines, system lines, unknown types, malformed JSON, future
// fields — are skipped without error. Duplicated assistant lines (same
// message.id + requestId, e.g. from resumed sessions rewriting history into
// the same file) are counted once, in both the cell totals and the heatmap.
//
// The project label prefers the transcript's own top-level cwd field —
// exact, unlike the fallback dir-name decode, which truncates dashed
// basenames ("tale-mode" → "mode"; Greptile P2 2026-07-11, cwd presence
// verified against real transcripts the same day).
func parseFile(path, fallbackProject string) ([]Cell, map[string]HourWeekday) {
	f, err := os.Open(path)
	if err != nil {
		return nil, nil
	}
	defer f.Close() //nolint:errcheck // read-only

	byKey := map[Cell]*Cell{}
	seen := map[string]struct{}{}
	hwByDay := map[string]HourWeekday{}
	project := ""
	// ReadBytes instead of a Scanner: transcript lines (pasted images,
	// thinking blocks) can exceed any fixed scanner buffer.
	r := bufio.NewReaderSize(f, 256<<10)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			if project == "" && bytes.Contains(line, []byte(`"cwd"`)) {
				var c struct {
					Cwd string `json:"cwd"`
				}
				if json.Unmarshal(line, &c) == nil && strings.HasPrefix(c.Cwd, "/") {
					if base := filepath.Base(c.Cwd); base != "" && base != "/" && base != "." {
						project = base
					}
				}
			}
			// cells accumulate with an empty Project; the resolved label is
			// stamped below (one project per file, so keys never collide).
			consumeLine(line, "", byKey, seen, hwByDay)
		}
		if err != nil {
			break // io.EOF or a read error: either way the file is done
		}
	}
	if project == "" {
		project = fallbackProject
	}

	cells := make([]Cell, 0, len(byKey))
	for _, c := range byKey {
		c.Project = project
		cells = append(cells, *c)
	}
	sort.Slice(cells, func(i, j int) bool {
		if cells[i].Model != cells[j].Model {
			return cells[i].Model < cells[j].Model
		}
		return cells[i].Day < cells[j].Day
	})
	return cells, hwByDay
}

func consumeLine(line []byte, project string, byKey map[Cell]*Cell, seen map[string]struct{}, hwByDay map[string]HourWeekday) {
	// Cheap pre-filter before JSON-decoding megabyte lines.
	if !bytes.Contains(line, []byte(`"assistant"`)) {
		return
	}
	var ln struct {
		Type      string `json:"type"`
		Timestamp string `json:"timestamp"`
		RequestID string `json:"requestId"`
		Message   struct {
			ID    string `json:"id"`
			Model string `json:"model"`
			Usage *struct {
				InputTokens              int64 `json:"input_tokens"`
				OutputTokens             int64 `json:"output_tokens"`
				CacheCreationInputTokens int64 `json:"cache_creation_input_tokens"`
				CacheReadInputTokens     int64 `json:"cache_read_input_tokens"`
			} `json:"usage"`
		} `json:"message"`
	}
	if json.Unmarshal(line, &ln) != nil {
		return
	}
	if ln.Type != "assistant" || ln.Message.Model == "" || ln.Message.Usage == nil {
		return
	}
	if ln.Message.ID != "" && ln.RequestID != "" {
		key := ln.Message.ID + "\x00" + ln.RequestID
		if _, dup := seen[key]; dup {
			return
		}
		seen[key] = struct{}{}
	}
	day := "unknown"
	if len(ln.Timestamp) >= 10 {
		day = ln.Timestamp[:10]
	}
	k := Cell{Model: ln.Message.Model, Day: day, Project: project}
	t, ok := byKey[k]
	if !ok {
		t = &Cell{Model: ln.Message.Model, Day: day, Project: project}
		byKey[k] = t
	}
	t.Messages++
	t.Tokens.add(Tokens{
		Input:         ln.Message.Usage.InputTokens,
		Output:        ln.Message.Usage.OutputTokens,
		CacheCreation: ln.Message.Usage.CacheCreationInputTokens,
		CacheRead:     ln.Message.Usage.CacheReadInputTokens,
	})

	// Heatmap: bucketed by the SAME UTC calendar day used for range
	// filtering (day, above) but by LOCAL weekday/hour — "when in my day did
	// I burn tokens" is a local-clock question even though the day cutoff
	// stays UTC-consistent with the cell aggregation. Entries with no
	// parseable timestamp simply don't contribute (never a fabricated hour).
	if ln.Timestamp != "" {
		if ts, err := time.Parse(time.RFC3339Nano, ln.Timestamp); err == nil {
			lt := ts.Local()
			grid := hwByDay[day]
			grid[int(lt.Weekday())][lt.Hour()] += ln.Message.Usage.InputTokens + ln.Message.Usage.OutputTokens
			hwByDay[day] = grid
		}
	}
}
