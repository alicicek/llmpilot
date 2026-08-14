# golden vectors

One JSON file per ported pure-logic module. During the native migration both
the web stack and the Swift stack read the SAME file and had to agree on
every case — that is how the native port stayed provably identical to the
web logic it replaced, without either side trusting the other's memory of
the rule.

Since the cockpit cutover the Swift tests are the sole executable reader:
the web runner retired with the Playwright suite, and `web/src` is frozen
(bugfix-only) while the browser cockpit ships for CLI-only installs. The
`want` values remain the record of the agreed behavior — a web bugfix that
touches a vectored module must be checked against the relevant file by hand
until the web cockpit retires entirely.

## Schema

```json
{
  "module": "name-of-the-ported-module",
  "source": {
    "web": "path/to/the/web/implementation",
    "swift": "path/to/the/swift/implementation"
  },
  "cases": [
    { "name": "human-readable case name", "input": { }, "want": "..." }
  ]
}
```

- `module` — short, stable id; matches the file name (`severity.json` ->
  `"module": "severity"`).
- `source.web` / `source.swift` — repo-relative paths to the two
  implementations under test, so a reader can jump straight to both sides.
- `cases` — table-test rows. `input` is whatever shape the module's pure
  function takes; `want` is its expected output — spelled in the WEB
  implementation's vocabulary (the web is the source being ported; the
  Swift reader maps its own names onto it, never the reverse). Case `name`
  must be unique within the file — it is what a failing assertion prints.
- `note` (optional) — what rule the file pins, incl. anything a reader
  might wrongly assume it doesn't cover (e.g. severity.json pins the
  server-override branch, not just percent thresholds).

## Reading a vector file

- **Swift** side: locate the file relative to `#filePath` (see
  `macos/Tests/GoldenVectorTests.swift`) so the test works regardless of the
  derived-data location xcodebuild runs from.
- **Web** side (historical): `web/tests/golden-vectors.spec.ts` imported the
  real web modules and ran every case; it retired with the Playwright suite
  at cutover, after both stacks were green on every file.

## Append-only

These files are append-only: add new cases, never edit or remove an existing
one's `input`/`want`. A vector that needs to change means the ported
behavior changed, which is a decision to make explicitly (new case + a note
in the module's own docs/comments), not a silent edit to a file the Swift
suite already trusts.
