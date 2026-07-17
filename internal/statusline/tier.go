package statusline

import (
	"fmt"
	"math"
	"strconv"
	"strings"
)

// Tier is the terminal's color capability. Rendering degrades through the
// tiers by SANITIZING: a color a tier cannot carry is downgraded to the
// nearest one it can (256→16) or stripped (plain) — stored configs never
// corrupt output on a lesser terminal (teardown: color-sanitize.ts).
type Tier int

const (
	TierPlain Tier = iota // no ANSI at all (NO_COLOR, dumb terminals)
	Tier16                // basic SGR colors
	Tier256               // xterm-256 palette
	TierRich              // truecolor + OKLab gradients
)

// String names the tier for the API and test output.
func (t Tier) String() string {
	switch t {
	case TierPlain:
		return "plain"
	case Tier16:
		return "16"
	case Tier256:
		return "256"
	default:
		return "truecolor"
	}
}

// TierFromString parses a tier name ("plain"/"standard"/"rich" aliases
// accepted for the proof vocabulary). Unknown → Tier16, the safe floor.
func TierFromString(s string) Tier {
	switch s {
	case "plain", "off", "0":
		return TierPlain
	case "16", "standard":
		return Tier16
	case "256":
		return Tier256
	case "truecolor", "rich", "24bit":
		return TierRich
	}
	return Tier16
}

// ResolveTier picks the render tier from the config pin and the environment.
// NO_COLOR always wins (we support it properly; ccstatusline doesn't at all);
// then an explicit config pin; then autodetection from COLORTERM/TERM.
func ResolveTier(colorSetting string, getenv func(string) string) Tier {
	if _, set := lookupEnv(getenv, "NO_COLOR"); set {
		return TierPlain
	}
	switch colorSetting {
	case "off":
		return TierPlain
	case "16":
		return Tier16
	case "256":
		return Tier256
	case "truecolor":
		return TierRich
	}
	term := getenv("TERM")
	if term == "dumb" || term == "" {
		return TierPlain
	}
	ct := getenv("COLORTERM")
	if ct == "truecolor" || ct == "24bit" {
		return TierRich
	}
	if strings.Contains(term, "256color") {
		return Tier256
	}
	return Tier16
}

// lookupEnv distinguishes "set to empty" from "unset" through a plain getenv
// func: NO_COLOR's contract is presence, not value. Callers pass os.Getenv in
// production; tests pass fakes — so the probe uses a sentinel-free heuristic:
// a non-empty value is definitely set; an empty one is treated as unset,
// which matches os.Getenv's information loss and errs toward color. The CLI
// entrypoint therefore checks os.LookupEnv("NO_COLOR") itself and passes
// colorSetting "off" — this path is the backstop.
func lookupEnv(getenv func(string) string, key string) (string, bool) {
	v := getenv(key)
	return v, v != ""
}

// Sem is a semantic style. Semantic colors render as the same classic SGR
// codes at every colored tier — that keeps the zero-config line byte-equal to
// the classic output whatever the terminal reports.
type Sem uint8

const (
	SemNone Sem = iota
	SemDim
	SemWarn
	SemCrit
	SemOK
	SemAccent
)

// Span is one styled run of text. Hex (from config colors or gradients) wins
// over Sem when the tier can carry color; both degrade per tier.
type Span struct {
	Text string
	Sem  Sem
	Hex  string // "#RRGGBB" or ""
}

func span(text string) Span           { return Span{Text: text} }
func spanSem(text string, s Sem) Span { return Span{Text: text, Sem: s} }
func spanHex(text, hex string) Span   { return Span{Text: text, Hex: hex} }

// paint renders spans for a tier. Plain strips everything.
func paint(spans []Span, tier Tier) string {
	var b strings.Builder
	for _, sp := range spans {
		code := sgrFor(sp, tier)
		if code == "" {
			b.WriteString(sp.Text)
			continue
		}
		b.WriteString("\x1b[")
		b.WriteString(code)
		b.WriteString("m")
		b.WriteString(sp.Text)
		b.WriteString("\x1b[0m")
	}
	return b.String()
}

func sgrFor(sp Span, tier Tier) string {
	if tier == TierPlain {
		return ""
	}
	if sp.Hex != "" {
		if r, g, bl, ok := parseHex(sp.Hex); ok {
			switch tier {
			case TierRich:
				return fmt.Sprintf("38;2;%d;%d;%d", r, g, bl)
			case Tier256:
				return "38;5;" + strconv.Itoa(nearestXterm(r, g, bl, 256))
			default:
				return ansi16Code(nearestXterm(r, g, bl, 16))
			}
		}
	}
	switch sp.Sem {
	case SemDim:
		return "2"
	case SemWarn:
		return "33"
	case SemCrit:
		return "31"
	case SemOK:
		return "32"
	case SemAccent:
		return "36"
	}
	return ""
}

// ansi16Code maps a 0-15 palette index to its classic SGR foreground code.
func ansi16Code(idx int) string {
	if idx < 8 {
		return strconv.Itoa(30 + idx)
	}
	return strconv.Itoa(90 + idx - 8)
}

func parseHex(s string) (r, g, b int, ok bool) {
	s = strings.TrimPrefix(s, "#")
	if len(s) != 6 {
		return 0, 0, 0, false
	}
	v, err := strconv.ParseUint(s, 16, 32)
	if err != nil {
		return 0, 0, 0, false
	}
	return int(v >> 16), int(v >> 8 & 0xff), int(v & 0xff), true
}

// --- OKLab: perceptually even interpolation and nearest-color distance
// (teardown: gradient.ts interpolates in OKLab; we do the same and also use
// it for palette downgrades).

type oklab struct{ l, a, b float64 }

func srgbToLinear(c float64) float64 {
	if c <= 0.04045 {
		return c / 12.92
	}
	return math.Pow((c+0.055)/1.055, 2.4)
}

func rgbToOKLab(r, g, b int) oklab {
	lr := srgbToLinear(float64(r) / 255)
	lg := srgbToLinear(float64(g) / 255)
	lb := srgbToLinear(float64(b) / 255)
	l := 0.4122214708*lr + 0.5363325363*lg + 0.0514459929*lb
	m := 0.2119034982*lr + 0.6806995451*lg + 0.1073969566*lb
	s := 0.0883024619*lr + 0.2817188376*lg + 0.6299787005*lb
	l, m, s = math.Cbrt(l), math.Cbrt(m), math.Cbrt(s)
	return oklab{
		l: 0.2104542553*l + 0.7936177850*m - 0.0040720468*s,
		a: 1.9779984951*l - 2.4285922050*m + 0.4505937099*s,
		b: 0.0259040371*l + 0.7827717662*m - 0.8086757660*s,
	}
}

func linearToSRGB(c float64) float64 {
	if c <= 0.0031308 {
		return 12.92 * c
	}
	return 1.055*math.Pow(c, 1/2.4) - 0.055
}

func oklabToRGB(c oklab) (int, int, int) {
	l := c.l + 0.3963377774*c.a + 0.2158037573*c.b
	m := c.l - 0.1055613458*c.a - 0.0638541728*c.b
	s := c.l - 0.0894841775*c.a - 1.2914855480*c.b
	l, m, s = l*l*l, m*m*m, s*s*s
	lr := 4.0767416621*l - 3.3077115913*m + 0.2309699292*s
	lg := -1.2684380046*l + 2.6097574011*m - 0.3413193965*s
	lb := -0.0041960863*l - 0.7034186147*m + 1.7076147010*s
	clamp := func(v float64) int {
		i := int(math.Round(linearToSRGB(v) * 255))
		if i < 0 {
			return 0
		}
		if i > 255 {
			return 255
		}
		return i
	}
	return clamp(lr), clamp(lg), clamp(lb)
}

// GradientHex interpolates between hex stops at t∈[0,1] in OKLab.
func GradientHex(stops []string, t float64) string {
	if len(stops) == 0 {
		return ""
	}
	if len(stops) == 1 {
		return stops[0]
	}
	if t < 0 {
		t = 0
	}
	if t > 1 {
		t = 1
	}
	scaled := t * float64(len(stops)-1)
	i := int(scaled)
	if i >= len(stops)-1 {
		i = len(stops) - 2
	}
	f := scaled - float64(i)
	r1, g1, b1, ok1 := parseHex(stops[i])
	r2, g2, b2, ok2 := parseHex(stops[i+1])
	if !ok1 || !ok2 {
		return stops[0]
	}
	c1, c2 := rgbToOKLab(r1, g1, b1), rgbToOKLab(r2, g2, b2)
	r, g, b := oklabToRGB(oklab{
		l: c1.l + (c2.l-c1.l)*f,
		a: c1.a + (c2.a-c1.a)*f,
		b: c1.b + (c2.b-c1.b)*f,
	})
	return fmt.Sprintf("#%02x%02x%02x", r, g, b)
}

// xtermPalette holds the 256 xterm default colors, built once.
var xtermPalette = buildXtermPalette()

func buildXtermPalette() [256][3]int {
	var p [256][3]int
	base := [16][3]int{
		{0, 0, 0}, {205, 0, 0}, {0, 205, 0}, {205, 205, 0},
		{0, 0, 238}, {205, 0, 205}, {0, 205, 205}, {229, 229, 229},
		{127, 127, 127}, {255, 0, 0}, {0, 255, 0}, {255, 255, 0},
		{92, 92, 255}, {255, 0, 255}, {0, 255, 255}, {255, 255, 255},
	}
	copy(p[:16], base[:])
	steps := []int{0, 95, 135, 175, 215, 255}
	for i := range 216 {
		p[16+i] = [3]int{steps[i/36], steps[i/6%6], steps[i%6]}
	}
	for i := range 24 {
		v := 8 + i*10
		p[232+i] = [3]int{v, v, v}
	}
	return p
}

// nearestXterm finds the closest palette entry (first `limit` entries) by
// OKLab distance.
func nearestXterm(r, g, b, limit int) int {
	target := rgbToOKLab(r, g, b)
	best, bestDist := 0, math.MaxFloat64
	for i := range limit {
		c := xtermPalette[i]
		lab := rgbToOKLab(c[0], c[1], c[2])
		dl, da, db := lab.l-target.l, lab.a-target.a, lab.b-target.b
		d := dl*dl + da*da + db*db
		if d < bestDist {
			best, bestDist = i, d
		}
	}
	return best
}
