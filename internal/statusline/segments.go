package statusline

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alicicek/llmpilot/internal/store"
	"github.com/alicicek/llmpilot/pilotapi"
)

// OptionSpec describes one editor-facing segment option. ONE registry drives
// both the binary and the cockpit editor's segment list (wave anchor).
type OptionSpec struct {
	Key     string   `json:"key"`
	Label   string   `json:"label"`
	Type    string   `json:"type"` // bool | enum | string | color
	Values  []string `json:"values,omitempty"`
	Default any      `json:"default,omitempty"`
}

func (o OptionSpec) valid(v any) bool {
	switch o.Type {
	case "bool":
		_, ok := v.(bool)
		return ok
	case "enum":
		s, ok := v.(string)
		if !ok {
			return false
		}
		for _, allowed := range o.Values {
			if s == allowed {
				return true
			}
		}
		return false
	case "string":
		s, ok := v.(string)
		return ok && len(s) <= 200 && !hasControl(s)
	case "color":
		s, ok := v.(string)
		if !ok {
			return false
		}
		_, _, _, hexOK := parseHex(s)
		return hexOK
	}
	return false
}

// Segment is one registry entry: identity and editor metadata plus the
// render function (and an optional narrower form the width collapse tries
// before dropping the segment entirely).
type Segment struct {
	ID       string
	Name     string
	Desc     string
	Deps     []string // data sources: stdin | store | daemon | git | exec
	Priority int      // collapse order: LOWER drops first
	Fleet    bool     // daemon-backed differentiator (editor badge)
	Options  []OptionSpec

	render func(ctx *Ctx, o segOpts) []Span
	narrow func(ctx *Ctx, o segOpts) []Span
}

func (s *Segment) option(key string) *OptionSpec {
	for i := range s.Options {
		if s.Options[i].Key == key {
			return &s.Options[i]
		}
	}
	return nil
}

type segOpts map[string]any

func (o segOpts) boolean(key string, def bool) bool {
	if v, ok := o[key].(bool); ok {
		return v
	}
	return def
}

func (o segOpts) str(key, def string) string {
	if v, ok := o[key].(string); ok && v != "" {
		return v
	}
	return def
}

// registry holds every segment; order defines the editor's palette order.
var (
	registryOrder []string
	registry      = map[string]*Segment{}
)

func register(s *Segment) {
	registry[s.ID] = s
	registryOrder = append(registryOrder, s.ID)
}

//nolint:gochecknoinits // the registry is static data, assembled once
func init() {
	register(&Segment{
		ID: "account", Name: "Account", Desc: "which account this terminal is on — [acct 2/4 | email]",
		Deps: []string{"store"}, Priority: 90,
		Options: []OptionSpec{{Key: "privacy", Label: "Hide email", Type: "bool", Default: false}},
		render:  renderAccount,
		narrow: func(ctx *Ctx, _ segOpts) []Span {
			return renderAccountPrivacy(ctx, true) // narrow form drops the email
		},
	})
	register(&Segment{
		ID: "usage", Name: "Usage", Desc: "the runway buckets — 5h, weekly, Fable weekly, anything the endpoint serves",
		Deps: []string{"store", "stdin"}, Priority: 100,
		Options: []OptionSpec{{
			Key: "mode", Label: "Display", Type: "enum",
			Values: []string{"percent", "bar", "time"}, Default: "percent",
		}},
		render: renderUsage,
		narrow: func(ctx *Ctx, _ segOpts) []Span {
			return renderUsage(ctx, segOpts{"mode": "percent"})
		},
	})
	register(&Segment{
		ID: "burn", Name: "Burn wall", Desc: "burn-rate projection: will this window hit 100% before it resets?",
		Deps: []string{"daemon"}, Priority: 80, Fleet: true,
		render: renderBurn,
	})
	register(&Segment{
		ID: "context", Name: "Context", Desc: "context window used, from Claude Code",
		Deps: []string{"stdin"}, Priority: 70,
		render: renderContext,
	})
	register(&Segment{
		ID: "dir", Name: "Directory", Desc: "working directory, with the git branch",
		Deps: []string{"stdin", "git"}, Priority: 65,
		Options: []OptionSpec{{Key: "branch", Label: "Show branch", Type: "bool", Default: true}},
		render:  renderDir,
		narrow: func(ctx *Ctx, _ segOpts) []Span {
			return renderDir(ctx, segOpts{"branch": false})
		},
	})
	register(&Segment{
		ID: "model", Name: "Model", Desc: "the session's model name",
		Deps: []string{"stdin"}, Priority: 60,
		render: renderModel,
	})
	register(&Segment{
		ID: "fleet", Name: "Fleet", Desc: "every account's session % on one glance — active starred",
		Deps: []string{"store"}, Priority: 55, Fleet: true,
		render: renderFleet,
	})
	register(&Segment{
		ID: "cost", Name: "Cost", Desc: "session cost estimate from Claude Code",
		Deps: []string{"stdin"}, Priority: 50,
		render: renderCost,
	})
	register(&Segment{
		// ID stays "rotation": it is persisted in saved statusline configs and
		// is an internal name, which the voice rules allow. The LABEL is what
		// users read, and that says "switch".
		ID: "rotation", Name: "Next switch", Desc: "where autopilot would switch next — →label:12%",
		Deps: []string{"store"}, Priority: 45, Fleet: true,
		render: renderRotation,
	})
	register(&Segment{
		ID: "autopilot", Name: "Autopilot", Desc: "autopilot state — on, off, or daemon down",
		Deps: []string{"store", "daemon"}, Priority: 40, Fleet: true,
		render: renderAutopilot,
	})
	register(&Segment{
		ID: "command", Name: "Command", Desc: "first line of a shell command's output (150ms budget)",
		Deps: []string{"exec"}, Priority: 30,
		Options: []OptionSpec{{Key: "command", Label: "Command", Type: "string", Default: ""}},
		render:  renderCommand,
	})
	register(&Segment{
		ID: "text", Name: "Text", Desc: "a fixed label, optionally colored",
		Deps: nil, Priority: 20,
		Options: []OptionSpec{
			{Key: "text", Label: "Text", Type: "string", Default: ""},
			{Key: "color", Label: "Color", Type: "color"},
		},
		render: renderText,
	})
}

// --- account -----------------------------------------------------------

func renderAccount(ctx *Ctx, o segOpts) []Span {
	return renderAccountPrivacy(ctx, o.boolean("privacy", false) || ctx.Privacy)
}

func renderAccountPrivacy(ctx *Ctx, privacy bool) []Span {
	ctx.resolve()
	pos := "?/?"
	if ctx.total > 0 {
		n := "?"
		if ctx.idx > 0 {
			n = fmt.Sprintf("%d", ctx.idx)
		}
		pos = fmt.Sprintf("%s/%d", n, ctx.total)
	}
	if privacy || ctx.email == "" {
		return []Span{span("[acct " + pos + "]")}
	}
	return []Span{span("[acct " + pos + " | " + ctx.email + "]")}
}

// --- usage --------------------------------------------------------------

// usageBuckets picks what to render and the honesty age token. The official
// stdin rate_limits — live by definition, and only ever present for the
// ACTIVE session — outrank the experimental endpoint's cache for the windows
// they carry; the cache fills in everything else (the scoped weekly, unknown
// kinds), wearing the age token once it is old enough to say so.
func usageBuckets(ctx *Ctx) (buckets []store.Bucket, age string) {
	ctx.resolve()
	var floor []store.Bucket
	// Floor guard: after a global swap an old session's stdin still carries
	// the OUTGOING account's windows; attribute the floor only while this
	// session's bound identity matches the dir's current one (floorguard.go).
	if ctx.floorAllowed() {
		if w := ctx.In.RateLimits.FiveHour; w != nil {
			floor = append(floor, w.Bucket("five_hour", ctx.Loc))
		}
		if w := ctx.In.RateLimits.SevenDay; w != nil {
			floor = append(floor, w.Bucket("seven_day", ctx.Loc))
		}
	}

	snap := ctx.snap
	cacheAge := time.Duration(-1)
	if snap != nil {
		cacheAge = ctx.Now.Sub(snap.AsOf)
	}

	switch {
	case len(floor) > 0:
		// Live official windows first; the cache keeps only the buckets the
		// floor doesn't carry (a missing fast window still renders from
		// cache — a stale reading with an age token beats a silent absence).
		hasFive := ctx.In.RateLimits.FiveHour != nil
		hasSeven := ctx.In.RateLimits.SevenDay != nil
		var extras []store.Bucket
		if snap != nil {
			for _, b := range snap.Buckets {
				replaced := (hasFive && (b.Kind == "session" || b.Kind == "five_hour")) ||
					(hasSeven && (b.Kind == "weekly_all" || b.Kind == "seven_day"))
				if !replaced {
					extras = append(extras, b)
				}
			}
		}
		buckets = append(floor, extras...)
		if len(extras) > 0 && cacheAge > AgeNoteAfter {
			age = FormatAge(cacheAge)
		}
	case snap != nil:
		// No live floor (an idle account's preview, a daemon-only render):
		// the cache speaks for everything, honestly aged.
		buckets = snap.Buckets
		if cacheAge > AgeNoteAfter {
			age = FormatAge(cacheAge)
		}
	}
	return buckets, age
}

func renderUsage(ctx *Ctx, o segOpts) []Span {
	buckets, age := usageBuckets(ctx)
	if len(buckets) == 0 {
		return []Span{span("no usage data — llmpilot daemon install")}
	}
	var spans []Span
	for i, b := range CanonicalOrder(buckets) {
		if i > 0 {
			spans = append(spans, span(" "))
		}
		switch o.str("mode", "percent") {
		case "bar":
			spans = append(spans, usageBarSpans(ctx, b)...)
		case "time":
			spans = append(spans, usageTimeSpans(ctx, b)...)
		default:
			spans = append(spans, spanSem(FormatBucket(b, ctx.Now, ctx.Loc), bucketSem(b)))
		}
	}
	if age != "" {
		spans = append(spans, span(" "), spanSem(age, SemDim))
	}
	return spans
}

// usageBarSpans renders `5h ▓▓│░░░░░░░ 23%` — the usage bar language with a
// │ time-cursor at the window's elapsed position (teardown: two bar
// languages). Rich terminals get an OKLab green→amber→red gradient across
// the filled cells; lesser tiers keep the severity color.
func usageBarSpans(ctx *Ctx, b store.Bucket) []Span {
	const cells = 10
	filled := int(b.Percent / 100 * cells)
	if filled > cells {
		filled = cells
	}
	cursor := -1
	if elapsed, ok := windowElapsedFraction(ctx, b); ok {
		cursor = int(elapsed * cells)
		if cursor >= cells {
			cursor = cells - 1
		}
	}
	sem := bucketSem(b)
	spans := []Span{span(BucketLabel(b) + " ")}
	for i := range cells {
		cell := "░"
		cellSem := SemDim
		if i < filled {
			cell = "▓"
			cellSem = sem
		}
		if i == cursor {
			cell = "│"
			cellSem = SemNone
		}
		if ctx.Tier == TierRich && cell == "▓" {
			spans = append(spans, spanHex(cell, GradientHex(usageGradient, float64(i)/(cells-1))))
			continue
		}
		spans = append(spans, spanSem(cell, cellSem))
	}
	spans = append(spans, span(" "), spanSem(FormatPercent(b.Percent)+"%", sem))
	return spans
}

// usageGradient is the calm→amber→red ramp for rich-tier bars.
var usageGradient = []string{"#1fa943", "#c86f00", "#d0342b"}

// usageTimeSpans renders reset-first: `5h ███░░░░░░░→14:32` for the session
// window (█░ is the timer bar language), `wk→Sun` for slower buckets.
func usageTimeSpans(ctx *Ctx, b store.Bucket) []Span {
	sem := bucketSem(b)
	label := BucketLabel(b)
	if b.ResetsAt == nil {
		return []Span{spanSem(label+":"+FormatPercent(b.Percent)+"%", sem)}
	}
	reset := formatReset(*b.ResetsAt, ctx.Now, ctx.Loc)
	if elapsed, ok := windowElapsedFraction(ctx, b); ok {
		const cells = 10
		filled := int(elapsed * cells)
		if filled > cells {
			filled = cells
		}
		bar := strings.Repeat("█", filled) + strings.Repeat("░", cells-filled)
		return []Span{span(label + " "), spanSem(bar, SemDim), spanSem("→"+reset, sem)}
	}
	return []Span{spanSem(label+"→"+reset, sem)}
}

// windowElapsedFraction reports how far through its window a session-group
// bucket is (only the 5h window has a known length).
func windowElapsedFraction(ctx *Ctx, b store.Bucket) (float64, bool) {
	session := b.Kind == "session" || b.Kind == "five_hour"
	if !session || b.ResetsAt == nil {
		return 0, false
	}
	remaining := b.ResetsAt.Sub(ctx.Now)
	if remaining < 0 || remaining > 5*time.Hour {
		return 0, false
	}
	return 1 - remaining.Hours()/5, true
}

// --- stdin-fed session segments ----------------------------------------

func renderModel(ctx *Ctx, _ segOpts) []Span {
	if ctx.In.Model.DisplayName == "" {
		return nil
	}
	return []Span{span(ctx.In.Model.DisplayName)}
}

func renderContext(ctx *Ctx, _ segOpts) []Span {
	p := ctx.In.ContextWindow.UsedPercentage
	if p == nil {
		return nil
	}
	sem := SemNone
	if *p >= 80 { // Claude Code autocompacts at ~80% — past it, attention
		sem = SemWarn
	}
	return []Span{spanSem("ctx:"+FormatPercent(*p)+"%", sem)}
}

func renderCost(ctx *Ctx, _ segOpts) []Span {
	c := ctx.In.Cost.TotalCostUSD
	if c == nil {
		return nil
	}
	return []Span{span(fmt.Sprintf("$%.2f", *c))}
}

func renderDir(ctx *Ctx, o segOpts) []Span {
	dir := ctx.In.Workspace.CurrentDir
	if dir == "" {
		dir = ctx.In.CWD
	}
	if dir == "" {
		return nil
	}
	out := filepath.Base(dir)
	if o.boolean("branch", true) {
		if br := gitBranch(dir); br != "" {
			out += " (" + br + ")"
		}
	}
	return []Span{span(out)}
}

// gitBranch reads .git/HEAD directly (no subprocess — the 50ms budget) from
// dir upward. Worktree .git FILES ("gitdir: …") are followed one hop.
func gitBranch(dir string) string {
	for range 8 {
		head := filepath.Join(dir, ".git", "HEAD")
		if fi, err := os.Stat(filepath.Join(dir, ".git")); err == nil && !fi.IsDir() {
			data, err := os.ReadFile(filepath.Join(dir, ".git"))
			if err != nil {
				return ""
			}
			gitdir := strings.TrimSpace(strings.TrimPrefix(string(data), "gitdir:"))
			head = filepath.Join(gitdir, "HEAD")
		}
		if data, err := os.ReadFile(head); err == nil {
			ref := strings.TrimSpace(string(data))
			if name, ok := strings.CutPrefix(ref, "ref: refs/heads/"); ok {
				return name
			}
			if len(ref) >= 7 { // detached HEAD: short sha
				return ref[:7]
			}
			return ""
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
	return ""
}

// --- fleet segments (daemon-backed moat) --------------------------------

func renderFleet(ctx *Ctx, _ segOpts) []Span {
	ctx.resolve()
	if len(ctx.accounts) == 0 {
		return nil
	}
	var spans []Span
	for i, a := range ctx.accounts {
		if i > 0 {
			spans = append(spans, span(" "))
		}
		label := a.Label
		if ctx.acct != nil && a.ID == ctx.acct.ID {
			label = "*" + label
		}
		snap := ctx.snapshot(a.ID)
		if snap == nil {
			spans = append(spans, spanSem(label+":—", SemDim))
			continue
		}
		b := fleetBucket(snap)
		spans = append(spans, spanSem(label+":"+FormatPercent(b.Percent)+"%", bucketSem(b)))
	}
	return spans
}

// fleetBucket is the one number per account: the session window when present,
// otherwise the highest bucket (limit proximity).
func fleetBucket(snap *store.UsageSnapshot) store.Bucket {
	var maxB store.Bucket
	for _, b := range snap.Buckets {
		if b.Kind == "session" || b.Kind == "five_hour" {
			return b
		}
		if b.Percent >= maxB.Percent {
			maxB = b
		}
	}
	return maxB
}

func renderRotation(ctx *Ctx, _ segOpts) []Span {
	ctx.resolve()
	if ctx.acct == nil || len(ctx.accounts) < 2 {
		return nil
	}
	p := pilotapi.ParamsFrom(ctx.pilotConfig().Autopilot)
	if !p.Enabled {
		return nil
	}
	// The preview shows the best ELIGIBLE candidate under the live policy —
	// same freshness/pinned/threshold filters Decide applies to targets.
	var best *store.Account
	bestUtil := 0.0
	for i := range ctx.accounts {
		a := ctx.accounts[i]
		if a.ID == ctx.acct.ID || a.Pinned {
			continue
		}
		snap := ctx.snapshot(a.ID)
		if snap == nil || ctx.Now.Sub(snap.AsOf) > p.MaxSnapshotAge {
			continue
		}
		util, _ := pilotapi.Utilization(snap)
		if util >= p.Threshold {
			continue
		}
		if best == nil || util < bestUtil {
			best, bestUtil = &ctx.accounts[i], util
		}
	}
	if best == nil {
		return nil
	}
	return []Span{spanSem("→"+best.Label+":"+FormatPercent(bestUtil)+"%", SemDim)}
}

func renderAutopilot(ctx *Ctx, _ segOpts) []Span {
	if ctx.pilotConfig().Autopilot.Disabled {
		return []Span{spanSem("auto:off", SemDim)}
	}
	if ctx.DaemonUp != nil && !ctx.DaemonUp() {
		return []Span{spanSem("auto:down", SemWarn)}
	}
	return []Span{spanSem("auto:on", SemDim)}
}

func renderBurn(ctx *Ctx, _ segOpts) []Span {
	ctx.resolve()
	if ctx.History == nil || ctx.acct == nil {
		return nil
	}
	b := ctx.sessionBucket()
	if b == nil {
		return nil
	}
	samples := ctx.History(ctx.acct.ID, b.Kind, b.Scope)
	wall, ok := projectWall(samples, ctx.Now)
	if !ok {
		return nil
	}
	if b.ResetsAt != nil && wall.Before(*b.ResetsAt) {
		return []Span{spanSem("wall "+wall.In(ctx.Loc).Format("15:04"), SemCrit)}
	}
	return []Span{spanSem("no wall", SemDim)}
}

// projectWall extrapolates when the window hits 100% from the recent burn
// rate (same math as the cockpit's burn view). It needs ≥2 samples within
// the last 45 minutes spanning ≥5 minutes and a positive rate — otherwise
// there is honestly nothing to project.
func projectWall(samples []Sample, now time.Time) (time.Time, bool) {
	cutoff := now.Add(-45 * time.Minute)
	var recent []Sample
	for _, s := range samples {
		if !s.At.Before(cutoff) && !s.At.After(now) {
			recent = append(recent, s)
		}
	}
	if len(recent) < 2 {
		return time.Time{}, false
	}
	first, last := recent[0], recent[len(recent)-1]
	dt := last.At.Sub(first.At)
	if dt < 5*time.Minute {
		return time.Time{}, false
	}
	rate := (last.Percent - first.Percent) / dt.Minutes() // %/min
	if rate <= 0 || last.Percent >= 100 {
		return time.Time{}, false
	}
	minutes := (100 - last.Percent) / rate
	return last.At.Add(time.Duration(minutes * float64(time.Minute))), true
}

// --- custom -------------------------------------------------------------

func renderText(_ *Ctx, o segOpts) []Span {
	text := o.str("text", "")
	if text == "" {
		return nil
	}
	if hex := o.str("color", ""); hex != "" {
		return []Span{spanHex(text, hex)}
	}
	return []Span{span(text)}
}

func renderCommand(ctx *Ctx, o segOpts) []Span {
	cmd := o.str("command", "")
	if cmd == "" {
		return nil
	}
	if ctx.Exec == nil {
		// Execution disabled (daemon preview): show what WOULD run, dimmed —
		// never pretend output, never run config-supplied shell from a GET.
		short := cmd
		if len(short) > 20 {
			short = short[:20] + "…"
		}
		return []Span{spanSem("("+short+")", SemDim)}
	}
	out, err := ctx.Exec(cmd)
	if err != nil {
		return nil
	}
	line := strings.TrimSpace(strings.SplitN(out, "\n", 2)[0])
	// Command output is untrusted for the one-line contract: strip control
	// bytes (raw ESC would let a script corrupt the terminal past our tiers).
	line = strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f {
			return -1
		}
		return r
	}, line)
	if line == "" {
		return nil
	}
	if r := []rune(line); len(r) > 80 {
		line = string(r[:80])
	}
	return []Span{span(line)}
}
