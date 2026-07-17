# Contributing

Thanks for looking. llmpilot is open core: everything in this repository is the
free app under MIT, and contributions to it are welcome.

## Build and test

llmpilot is one Go binary plus a React cockpit and a SwiftUI menu bar.

```sh
make build   # go build -o ./llmpilot ./cmd/llmpilot
make test    # go test ./...
make lint    # golangci-lint run
make check   # all of the above
```

- **Cockpit** (`web/`): `cd web && pnpm install && pnpm dev`; build with
  `pnpm build`. The built assets are embedded into the Go binary via `go:embed`.
- **Menu bar** (`macos/`): open in Xcode, or
  `xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot build test`.
- macOS only for now.

Please run `make check` before opening a pull request. Web changes should also
pass `cd web && pnpm build` and `npx impeccable detect web/src/`.

## Layout

- `cmd/llmpilot/` — entrypoint.
- `internal/<domain>/` — the daemon, CLI, statusline, usage/OAuth adapters, and
  credential switching.
- `web/` — the React cockpit.
- `macos/` — the SwiftUI menu bar (talks to the daemon API only).
- `worker/` — the Cloudflare worker for Pro licensing.

The Pro engine (the autopilot's policy, scheduler, and wake helper) lives in a
separate private module and is not part of this repository. The build selects it
in only when present, so this tree builds and runs as the complete free app on
its own.

## Conventions

- **Commits:** [Conventional Commits](https://www.conventionalcommits.org/)
  (`feat`, `fix`, `docs`, `chore`, `ci`, `test`, optional scope; imperative
  subject ≤ 72 chars; body says *why*).
- **Fragile surfaces** — the usage endpoint, the OAuth token endpoint, the
  Keychain service naming, and Claude Code's config/lock layout — stay behind
  their adapters in `internal/anthropic` and `internal/claudecfg`. Don't spread
  that knowledge elsewhere.
- **Secrets and tokens** never go in logs, errors, cache files, or the repo.
  Cache files hold percentages and reset timestamps only.
- Add a feature only with a test that exercises its failure case too.

## Reporting bugs and ideas

Use the issue templates. For anything security-sensitive, follow
[SECURITY.md](SECURITY.md) and report privately rather than in a public issue.
