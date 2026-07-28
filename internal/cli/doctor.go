package cli

// The terminal rendering of the health sweep. The findings themselves come
// from internal/doctor — the one check engine both this and the cockpit read,
// so the terminal can never contradict the cockpit about whether the fleet is
// healthy.

import (
	"fmt"
	"io"
	"strings"

	"github.com/alicicek/llmpilot/internal/doctor"
)

// severityWord is the terminal's word for each severity. "NOTE" is
// deliberate: an informational finding (a watched lane) is not a problem, and
// printing it as a warning would train people to ignore the real ones.
func severityWord(s doctor.Severity) string {
	switch s {
	case doctor.Critical:
		return "CRITICAL"
	case doctor.Warning:
		return "WARNING"
	default:
		return "NOTE"
	}
}

// RenderDoctor writes the report: a headline that can never overstate what
// was checked, every finding with its one remedy, then the coverage — what
// could not be checked (and why) before what was.
//
// degradedNote is empty for a report the daemon served, and otherwise says WHY
// this sweep ran locally — in the same words as the finding below it. A fixed
// "daemon not running" banner over a finding that says the daemon IS running
// is a contradiction the reader has to resolve themselves.
func RenderDoctor(w io.Writer, rep *doctor.Report, degradedNote string) {
	if degradedNote != "" {
		fmt.Fprintln(w, degradedNote)
	}
	var notChecked []doctor.Check
	var checked []string
	for _, c := range rep.Checks {
		if c.State == doctor.StateNotChecked {
			notChecked = append(notChecked, c)
			continue
		}
		checked = append(checked, plain(c.Title))
	}

	notes := len(rep.Findings) - rep.Problems
	// Defence in depth, the same rule the cockpit applies: the all-clear needs
	// BOTH the engine's verdict and no unchecked item in the list printed
	// below it. This document may have come off the wire from a daemon whose
	// flag is wrong; a clean bill directly above "Not checked (3)" is the
	// contradiction this guard exists to prevent.
	switch {
	case rep.Clean && len(notChecked) == 0 && rep.Problems == 0:
		fmt.Fprintf(w, "No problems found — all %d checks ran.\n", len(rep.Checks))
	case rep.Problems > 0:
		fmt.Fprintf(w, "%s found.\n", plural(rep.Problems, "problem"))
	case len(notChecked) > 0:
		fmt.Fprintf(w, "No problems found, but %d of %d checks could not run.\n",
			len(notChecked), len(rep.Checks))
	default:
		// No problems, nothing unchecked, and still not clean: the document
		// contradicts itself, so llmpilot says that instead of picking whichever
		// half flatters the fleet.
		fmt.Fprintln(w, "This report does not add up — llmpilot cannot confirm the fleet is healthy.")
	}
	if notes > 0 {
		fmt.Fprintf(w, "%s below.\n", plural(notes, "note"))
	}

	// Nothing is truncated — llmpilot's own findings run to ~370 runes and a
	// cap cut the coverage promise off mid-word. Every line is WRAPPED
	// instead, which bounds the terminal without losing a sentence; a served
	// document's foreign text is bounded at the engine boundary (excerpt).
	for _, f := range rep.Findings {
		title := wrap(plain(f.Title), 68)
		fmt.Fprintf(w, "\n%-8s  %s\n", severityWord(f.Severity), title[0])
		for _, line := range title[1:] {
			fmt.Fprintf(w, "          %s\n", line)
		}
		for _, line := range wrap(plain(f.Detail), 72) {
			fmt.Fprintf(w, "          %s\n", line)
		}
		remedy := plain(f.Remedy.Label)
		if f.Remedy.Command != "" {
			remedy += ": " + plain(f.Remedy.Command)
		}
		for i, line := range wrap(remedy, 70) {
			prefix := "          → "
			if i > 0 {
				prefix = "            "
			}
			fmt.Fprintln(w, prefix+line)
		}
	}

	// Every composed line is wrapped as well as bounded per field: two capped
	// fields still make one long line, and this document may have been served.
	if len(notChecked) > 0 {
		fmt.Fprintf(w, "\nNot checked (%d):\n", len(notChecked))
		for _, c := range notChecked {
			for i, line := range wrap(plain(c.Title)+" — "+plain(c.Why), 72) {
				prefix := "  "
				if i > 0 {
					prefix = "    "
				}
				fmt.Fprintln(w, prefix+line)
			}
		}
	}
	if len(checked) > 0 {
		fmt.Fprintln(w)
		for i, line := range wrap("Checked: "+strings.Join(checked, " · "), 72) {
			if i > 0 {
				line = "  " + line
			}
			fmt.Fprintln(w, line)
		}
	}
}

// plain strips control bytes from a string before it reaches the terminal.
// This report may have been SERVED — the renderer does not compute it — and a
// document with an escape sequence in a title could rewrite the lines above
// it. Everything the doctor emits is plain prose, so nothing legitimate is
// lost.
func plain(s string) string {
	s = strings.Map(func(r rune) rune {
		switch {
		case r < 0x20 || r == 0x7f: // C0 + DEL
			return ' '
		case r >= 0x80 && r <= 0x9f: // C1, including CSI at U+009B
			return ' '
		case r >= 0x202a && r <= 0x202e, r >= 0x2066 && r <= 0x2069,
			r == 0x200e, r == 0x200f, r == 0x061c:
			// Bidi controls — overrides, isolates AND the marks. All of them
			// can reverse the DISPLAY of a command while the clipboard keeps
			// the real order, so what the user pastes is not what they read
			// (the CVE-2021-42574 family).
			return ' '
		}
		return r
	}, s)
	return s
}

func plural(n int, word string) string {
	if n == 1 {
		return fmt.Sprintf("%d %s", n, word)
	}
	return fmt.Sprintf("%d %ss", n, word)
}

// wrap breaks a sentence at word boundaries so a detail reads as a paragraph
// in an 80-column terminal instead of one runaway line. A single "word" longer
// than the width is hard-split: this report may have been SERVED, and one
// 5000-character token would otherwise run straight off the terminal — the
// bound that replaced truncating llmpilot's own prose.
func wrap(s string, width int) []string {
	var words []string
	for _, w := range strings.Fields(s) {
		for r := []rune(w); len(r) > width; r = r[width:] {
			words = append(words, string(r[:width]))
			w = string(r[width:])
		}
		words = append(words, w)
	}
	if len(words) == 0 {
		return []string{""}
	}
	var out []string
	line := words[0]
	for _, word := range words[1:] {
		if len([]rune(line))+1+len([]rune(word)) > width {
			out = append(out, line)
			line = word
			continue
		}
		line += " " + word
	}
	return append(out, line)
}
