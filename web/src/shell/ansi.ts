// Minimal ANSI SGR parser for the statusline preview: the daemon returns the
// binary's exact bytes, so the editor renders the escapes the engine can emit
// (reset, dim, classic 30-37/90-97, 38;5;n, 38;2;r;g;b) — nothing more.

export interface AnsiSpan {
  text: string;
  color?: string; // CSS color
  dim?: boolean;
}

// Classic foreground colors tuned to read on the dark preview strip.
const BASIC: Record<number, string> = {
  30: "#a5a5ac",
  31: "#ff6f61",
  32: "#3ddc68",
  33: "#ffb340",
  34: "#6aa8ff",
  35: "#e58cff",
  36: "#54d1db",
  37: "#f5f5f7",
};

function xterm256(n: number): string {
  if (n < 16) {
    const base = [
      "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
      "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
    ];
    return base[n];
  }
  if (n < 232) {
    const steps = [0, 95, 135, 175, 215, 255];
    const i = n - 16;
    const r = steps[Math.floor(i / 36)];
    const g = steps[Math.floor(i / 6) % 6];
    const b = steps[i % 6];
    return `rgb(${r},${g},${b})`;
  }
  const v = 8 + (n - 232) * 10;
  return `rgb(${v},${v},${v})`;
}

export function parseAnsi(line: string): AnsiSpan[] {
  const spans: AnsiSpan[] = [];
  let color: string | undefined;
  let dim = false;
  let buf = "";
  const flush = () => {
    if (buf) spans.push({ text: buf, color, dim });
    buf = "";
  };
  let i = 0;
  while (i < line.length) {
    if (line[i] === "\x1b" && line[i + 1] === "[") {
      const end = line.indexOf("m", i + 2);
      if (end === -1) break;
      flush();
      const codes = line
        .slice(i + 2, end)
        .split(";")
        .map((c) => parseInt(c, 10));
      for (let j = 0; j < codes.length; j++) {
        const c = codes[j];
        if (c === 0) {
          color = undefined;
          dim = false;
        } else if (c === 2) {
          dim = true;
        } else if (c >= 30 && c <= 37) {
          color = BASIC[c];
        } else if (c >= 90 && c <= 97) {
          color = BASIC[c - 60];
        } else if (c === 38 && codes[j + 1] === 5) {
          color = xterm256(codes[j + 2] ?? 0);
          j += 2;
        } else if (c === 38 && codes[j + 1] === 2) {
          color = `rgb(${codes[j + 2] ?? 0},${codes[j + 3] ?? 0},${codes[j + 4] ?? 0})`;
          j += 4;
        }
      }
      i = end + 1;
      continue;
    }
    buf += line[i];
    i++;
  }
  flush();
  return spans;
}
