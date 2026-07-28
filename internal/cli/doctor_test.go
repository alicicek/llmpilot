package cli

import (
	"bytes"
	"strings"
	"testing"

	"github.com/alicicek/llmpilot/internal/doctor"
)

// The renderer does not COMPUTE the report — it prints one that may have come
// off the wire. These are the two things it must therefore never do: repeat a
// clean bill it can see is wrong, and replay bytes it did not generate.
func TestRenderDoctorDistrustsTheDocument(t *testing.T) {
	t.Run("a clean flag over a blind spot is not an all-clear", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			// Only a daemon whose flag is wrong produces this pair — which is
			// exactly the case worth surviving.
			Clean:    true,
			Findings: []doctor.Finding{},
			Checks: []doctor.Check{
				{ID: "daemon", Title: "the daemon", State: doctor.StateOK},
				{ID: "frozen_accounts", Title: "frozen accounts", State: doctor.StateNotChecked,
					Why: "the daemon is not running, so llmpilot cannot see this"},
			},
		}, "")
		out := buf.String()
		if strings.Contains(out, "No problems found — all") {
			t.Errorf("printed a clean bill directly above a blind spot:\n%s", out)
		}
		if !strings.Contains(out, "Not checked (1)") {
			t.Errorf("the blind spot was not named:\n%s", out)
		}
	})

	t.Run("a served document cannot rewrite the terminal", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			Problems: 1,
			Findings: []doctor.Finding{{
				ID: "x", Severity: doctor.Critical,
				Title:    "a title\x1b[2K\x1b[1G INJECTED",
				Detail:   "a detail\x1b[31m in red",
				Accounts: []string{},
				// The command is the highest-value target in the whole render:
				// it is the string the product invites the user to paste into
				// a shell.
				Remedy: doctor.Remedy{Verb: doctor.VerbNone, Label: "nothing\x07",
					Command: "echo safe\x1b[2K\x1b[1G rm -rf ~\u202e\u200f\u200e\u061c"},
			}},
			Checks: []doctor.Check{
				{ID: "c", Title: "a check\x1b[1m", State: doctor.StateNotChecked, Why: "because\x1b[0m"},
				// ...and the "Checked:" list is rendered from a different call
				// site, so it needs its own dirty value.
				{ID: "ran", Title: "a ran check\x1b[7m\u009b2K", State: doctor.StateOK},
			},
		}, "")
		out := buf.String()
		// The bidi MARKS matter as much as the overrides: they reverse the
		// display of a command while the clipboard keeps the real order.
		for _, b := range []string{"\x1b", "\x07", "\u202e", "\u009b", "\u200e", "\u200f", "\u061c"} {
			if strings.Contains(out, b) {
				t.Errorf("a control byte from the document reached the terminal: %q", out)
			}
		}
		// ...and the prose still renders.
		if !strings.Contains(out, "INJECTED") || !strings.Contains(out, "in red") {
			t.Errorf("stripping ate the text:\n%s", out)
		}
	})

	t.Run("a clean flag over real problems is not an all-clear", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			// The engine cannot emit this pair; a daemon whose flag is wrong
			// can, and a wrong flag can be wrong in either direction.
			Clean:    true,
			Problems: 2,
			Findings: []doctor.Finding{
				{ID: "a", Severity: doctor.Critical, Title: "one", Accounts: []string{}},
				{ID: "b", Severity: doctor.Warning, Title: "two", Accounts: []string{}},
			},
			Checks: []doctor.Check{{ID: "c", Title: "a check", State: doctor.StateFinding}},
		}, "")
		if strings.Contains(buf.String(), "No problems found") {
			t.Errorf("printed a clean bill above two problems:\n%s", buf.String())
		}
		if !strings.Contains(buf.String(), "2 problems found") {
			t.Errorf("the problems were not counted:\n%s", buf.String())
		}
	})

	t.Run("a report that contradicts itself says so", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			// Not clean, nothing wrong, nothing unchecked: incoherent.
			Findings: []doctor.Finding{},
			Checks:   []doctor.Check{{ID: "c", Title: "a check", State: doctor.StateOK}},
		}, "")
		out := buf.String()
		if !strings.Contains(out, "does not add up") {
			t.Errorf("an incoherent report was rendered as an answer:\n%s", out)
		}
		if strings.Contains(out, "0 of 1 checks could not run") {
			t.Errorf("printed a count that means nothing:\n%s", out)
		}
	})

	t.Run("a served string cannot run off the end of the terminal", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			Problems: 1,
			Findings: []doctor.Finding{{
				ID: "x", Severity: doctor.Critical, Title: strings.Repeat("t", 5000),
				Accounts: []string{}, Remedy: doctor.Remedy{Verb: doctor.VerbNone, Label: strings.Repeat("l", 5000)},
			}},
			Checks: []doctor.Check{{ID: "c", Title: strings.Repeat("c", 5000), State: doctor.StateNotChecked, Why: strings.Repeat("w", 5000)}},
		}, "")
		for _, line := range strings.Split(buf.String(), "\n") {
			if len(line) > 100 {
				t.Errorf("a %d-byte line reached the terminal from a served document", len(line))
			}
		}
		// ...and nothing was TRUNCATED to achieve that: every rune is still
		// there, just wrapped.
		if n := strings.Count(buf.String(), "t"); n < 5000 {
			t.Errorf("only %d of 5000 title runes survived — wrapping must not truncate", n)
		}
	})

	// The regression this replaced: a length cap cut llmpilot's OWN longest
	// finding off mid-word, losing the sentence that states the coverage.
	t.Run("llmpilot's own longest finding renders whole", func(t *testing.T) {
		detail := "Something is listening where llmpilot's daemon listens: it answered 404. " +
			"That is usually a daemon older than this copy of llmpilot, or one whose own health check is failing. " +
			"(If you started it yourself with `llmpilot daemon run`, restart that process instead.) " +
			"The checks that need the daemon could not run below."
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{
			Problems: 1,
			Findings: []doctor.Finding{{
				ID: "daemon_unreachable", Severity: doctor.Critical, Accounts: []string{},
				Title: "llmpilot cannot read the daemon's health report", Detail: detail,
				Remedy: doctor.Remedy{Verb: doctor.VerbInstallDaemon, Label: "Restart the daemon",
					Command: "launchctl kickstart -k gui/501/dev.llmpilot.daemon"},
			}},
			Checks: []doctor.Check{{ID: "daemon", Title: "the daemon", State: doctor.StateFinding}},
		}, "")
		out := buf.String()
		if strings.Contains(out, "…") {
			t.Errorf("llmpilot's own copy was truncated:\n%s", out)
		}
		for _, sentence := range []string{
			"The checks that need the daemon could not run below.",
			"restart that process instead.",
			"launchctl kickstart -k gui/501/dev.llmpilot.daemon",
		} {
			flat := strings.Join(strings.Fields(out), " ")
			if !strings.Contains(flat, sentence) {
				t.Errorf("missing from the render: %q\n%s", sentence, out)
			}
		}
	})

	t.Run("the degraded note is the caller's, not a fixed string", func(t *testing.T) {
		var buf bytes.Buffer
		RenderDoctor(&buf, &doctor.Report{Findings: []doctor.Finding{}, Checks: []doctor.Check{
			{ID: "daemon", Title: "the daemon", State: doctor.StateOK},
		}}, "the daemon did not answer with a health report")
		if !strings.Contains(buf.String(), "did not answer with a health report") {
			t.Errorf("the caller's reason was not printed:\n%s", buf.String())
		}
		if strings.Contains(buf.String(), "daemon not running") {
			t.Errorf("a fixed banner overrode the caller's reason:\n%s", buf.String())
		}
	})
}
