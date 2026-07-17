BINARY := llmpilot
GORELEASER_VERSION := v2.17.0

.PHONY: build test lint check web worker goreleaser-check

# The committed web/dist/.gitkeep satisfies web/embed.go's go:embed on a
# clean checkout (the daemon serves an honest "cockpit not built" page), so
# bare `go build/test` always work. A SHIPPING binary must embed the real
# cockpit — `make build` and the goreleaser before-hook build it first.
web:
	cd web && pnpm install --frozen-lockfile && pnpm build

build: web
	go build -o ./$(BINARY) ./cmd/llmpilot

test:
	go test ./...

lint:
	golangci-lint run

worker:
	cd worker && npm ci && npm run types && npm run check && npm test

check: build test lint worker

goreleaser-check:
	go run github.com/goreleaser/goreleaser/v2@$(GORELEASER_VERSION) check
