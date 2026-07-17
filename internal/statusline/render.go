package statusline

// Flex modes: how much of the terminal the line may use. full-minus-40 is
// the default — it reserves Claude Code's own chrome on the same row
// (teardown: renderer.ts flex modes).
const (
	FlexFull        = "full"
	FlexFullMinus40 = "full-minus-40"
	FlexOff         = "off"
)

// widthBudget converts a flex mode + terminal width into a character budget.
// 0 means "no limit" (width unknown, or flex off).
func widthBudget(flex string, width int) int {
	if width <= 0 || flex == FlexOff {
		return 0
	}
	switch flex {
	case FlexFull:
		width -= 6
	default: // FlexFullMinus40 and "" (the default)
		width -= 40
	}
	if width < 10 {
		width = 10 // a sliver of terminal still renders the top segment
	}
	return width
}

// renderedSeg is one segment's output during collapse.
type renderedSeg struct {
	seg      *Segment
	opts     segOpts
	spans    []Span
	width    int
	narrowed bool
}

// Render produces the one-line statusline for a config. Segments render in
// config order; when the width budget is exceeded, lower-priority segments
// first try their narrow form, then drop entirely — lowest priority first,
// rightmost first on ties. The result carries ANSI per ctx.Tier.
func Render(cfg Config, ctx *Ctx) string {
	ctx.defaults()
	sep := cfg.separator()

	var items []*renderedSeg
	for _, sc := range cfg.Segments {
		seg, ok := registry[sc.ID]
		if !ok {
			continue // forward-compat: a newer file's segment just doesn't render
		}
		spans := seg.render(ctx, segOpts(sc.Options))
		if len(spans) == 0 {
			continue
		}
		items = append(items, &renderedSeg{
			seg: seg, opts: segOpts(sc.Options), spans: spans, width: spansWidth(spans),
		})
	}
	if len(items) == 0 {
		return ""
	}

	if budget := widthBudget(cfg.Flex, ctx.Width); budget > 0 {
		items = collapse(items, ctx, budget, len([]rune(sep)))
	}

	var all []Span
	for i, it := range items {
		if i > 0 {
			all = append(all, span(sep))
		}
		all = append(all, it.spans...)
	}
	return paint(all, ctx.Tier)
}

func spansWidth(spans []Span) int {
	w := 0
	for _, sp := range spans {
		w += len([]rune(sp.Text))
	}
	return w
}

func lineWidth(items []*renderedSeg, sepW int) int {
	w := 0
	for i, it := range items {
		if i > 0 {
			w += sepW
		}
		w += it.width
	}
	return w
}

// collapse fits items into the budget: first narrow, then drop, both in
// ascending priority (position breaks ties — the rightmost goes first).
func collapse(items []*renderedSeg, ctx *Ctx, budget, sepW int) []*renderedSeg {
	order := func() []int {
		idx := make([]int, len(items))
		for i := range idx {
			idx[i] = i
		}
		// selection order: lowest priority first; among equals, rightmost.
		for i := 0; i < len(idx); i++ {
			for j := i + 1; j < len(idx); j++ {
				a, b := items[idx[i]], items[idx[j]]
				if b.seg.Priority < a.seg.Priority ||
					(b.seg.Priority == a.seg.Priority && idx[j] > idx[i]) {
					idx[i], idx[j] = idx[j], idx[i]
				}
			}
		}
		return idx
	}

	for _, i := range order() {
		if lineWidth(items, sepW) <= budget {
			return items
		}
		it := items[i]
		if it.seg.narrow == nil || it.narrowed {
			continue
		}
		if spans := it.seg.narrow(ctx, it.opts); len(spans) > 0 {
			narrowW := spansWidth(spans)
			if narrowW < it.width {
				it.spans, it.width, it.narrowed = spans, narrowW, true
			}
		}
	}

	for lineWidth(items, sepW) > budget && len(items) > 1 {
		drop := 0
		for i := 1; i < len(items); i++ {
			a, b := items[drop], items[i]
			if b.seg.Priority < a.seg.Priority ||
				(b.seg.Priority == a.seg.Priority && i > drop) {
				drop = i
			}
		}
		items = append(items[:drop], items[drop+1:]...)
	}
	return items
}

// SegmentSpec is the registry entry served to the cockpit editor.
type SegmentSpec struct {
	ID       string       `json:"id"`
	Name     string       `json:"name"`
	Desc     string       `json:"desc"`
	Deps     []string     `json:"deps,omitempty"`
	Priority int          `json:"priority"`
	Fleet    bool         `json:"fleet,omitempty"`
	Options  []OptionSpec `json:"options,omitempty"`
}

// Specs lists every registered segment in palette order — the ONE registry
// drives both the binary and the editor.
func Specs() []SegmentSpec {
	out := make([]SegmentSpec, 0, len(registryOrder))
	for _, id := range registryOrder {
		s := registry[id]
		out = append(out, SegmentSpec{
			ID: s.ID, Name: s.Name, Desc: s.Desc, Deps: s.Deps,
			Priority: s.Priority, Fleet: s.Fleet, Options: s.Options,
		})
	}
	return out
}
