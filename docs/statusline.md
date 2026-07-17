# Statusline

`llmpilot statusline` prints one line for Claude Code's `statusLine` hook.
Zero config renders the classic runway line; `$LLMPILOT_HOME/statusline.json`
(or the cockpit editor: Settings → Statusline) makes it yours.

## Install

```
llmpilot statusline install
```

Writes `"statusLine": {"type": "command", "command": "<binary> statusline"}`
into `~/.claude/settings.json` (full-file backup at `settings.json.orig`,
made once). If settings.json already carries **someone else's statusline, it
is kept** — the command shows what it found and how to take over:

```
llmpilot statusline install --replace   # backs up the old line
llmpilot statusline uninstall           # restores it, exactly as it was
```

Uninstall splices the previous statusLine value back without touching any
setting you changed since. Writes touch only the `statusLine` key — other
values pass through verbatim, though the file's key order and indentation
are normalized (the `.orig` backup keeps your original bytes).

### Keep yours AND add ours (coexist)

```
llmpilot statusline install --keep
```

Your existing statusline keeps rendering — colors, multiple lines, all of it
— and the llmpilot line prints below it (Claude Code renders every line a
statusline command emits). Under the hood: your command is recorded as
`keep.command` in statusline.json; the binary runs it with the same session
JSON Claude Code sends us (1 s budget) and prints its output first. If it
ever fails, the line says so instead of silently vanishing.
`llmpilot statusline uninstall` puts your original back exactly and clears
the keep. The cockpit editor shows the kept command and can remove it.

## Segments

One registry drives the binary, the daemon preview, and the cockpit editor.
Segments render in config order; anything without data hides honestly.

| id | shows | source |
|---|---|---|
| `account` | `[acct 2/4 \| you@example.dev]` (option: hide email) | store |
| `usage` | the runway buckets — `5h:23%(14:32) wk:41% F:67%(Sun)`; modes `percent` / `bar` / `time` | store + stdin floor |
| `burn` | `wall 15:40` when the current burn rate hits 100% before the reset, else `no wall` | daemon history |
| `context` | `ctx:34%` (amber ≥80%, the autocompact point) | stdin |
| `dir` | `llmpilot (main)` — cwd basename + git branch (`.git/HEAD` read, no subprocess) | stdin + fs |
| `model` | `Fable` | stdin |
| `fleet` | every account at a glance — `one:— *two:23% three:12%` (active starred, `—` = no data) | store |
| `cost` | `$3.42` session estimate | stdin |
| `rotation` | `→alt:12%` — where autopilot would switch next (live policy filters) | store |
| `autopilot` | `auto:on` / `auto:off` / `auto:down` (daemon not answering) | store + socket |
| `command` | first line of a shell command (150 ms budget) | exec |
| `text` | a fixed label, optionally colored | — |

`burn`, `fleet`, `rotation`, and `autopilot` are daemon-backed — segments a
stateless statusline script cannot render.

The honesty rules carry over: a cache older than 2 min gets a dim `~4m`
age token; past 10 min the live stdin floor replaces the fast windows.

## Config file

```json
{
  "version": 1,
  "separator": " ",
  "flex": "full-minus-40",
  "color": "auto",
  "segments": [
    {"id": "account", "options": {"privacy": false}},
    {"id": "usage", "options": {"mode": "percent"}}
  ]
}
```

- **Never-clobber:** an unreadable file renders defaults and is left on disk
  untouched. Loading migrates old/unversioned files by allowlist (unknown
  segments, options, and values drop; nothing is blindly spread). Saving
  (CLI `preset`, cockpit Apply) validates strictly.
- **flex:** the zero-config default is `off` — the classic line never
  collapses, at any width (the byte-parity guarantee). Customized lines
  default to `full-minus-40`, which reserves Claude Code's own chrome on the
  row; `full` reserves 6; `off` never collapses. Width comes from `COLUMNS`
  (Claude Code exports it ≥2.1.153) with a `tput cols` fallback. Over
  budget, segments first try a narrower form (account drops the email, dir
  drops the branch, usage bars fall back to percent), then drop whole —
  lowest priority first. (This narrow-form step is how the segment
  contract's minWidth idea shipped.)
- **color:** `auto` detects from `COLORTERM`/`TERM`; or pin `off`/`16`/
  `256`/`truecolor`. `NO_COLOR` always wins. Hex colors sanitize on
  downgrade (truecolor → nearest xterm-256 → nearest basic → stripped);
  gradients interpolate in OKLab and only engage at truecolor. Semantic
  colors stay classic SGR at every tier, so the default line is byte-stable.

## Presets

`llmpilot statusline preset` lists; `preset <id>` applies.

- `runway` — the default; byte-identical to the classic line.
- `pilot` — runway + burn wall, next rotation, autopilot state.
- `dev` — `dir (branch) · model · ctx · cost` + the runway.

## Preview == production

The cockpit editor's preview is `GET /v1/statusline/preview`: the daemon runs
the same Go renderer over its live store and returns the exact bytes the
binary prints (tested byte-equal). Session-scoped fields (model, dir, cost,
context) preview with fixed sample values — the daemon has no live session.
`command` segments are **never executed** by the preview (a GET must not
reach the shell); they render as a dim placeholder there.
