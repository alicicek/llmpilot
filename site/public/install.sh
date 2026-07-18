#!/bin/sh
# llmpilot installer — a Homebrew bootstrap, nothing more. The tap is the
# distribution channel; this script exists so the site's `curl | sh` works.
# Everything runs from main() invoked on the last line, so a truncated
# download executes nothing.
set -eu

main() {
  case "$(uname -s)" in
    Darwin) ;;
    *)
      echo "llmpilot is macOS-only for now."
      exit 1
      ;;
  esac

  if ! command -v brew >/dev/null 2>&1; then
    echo "llmpilot installs via Homebrew, which isn't on this Mac."
    echo "Get Homebrew at https://brew.sh — or download the app directly:"
    echo "  https://github.com/alicicek/llmpilot/releases/latest"
    exit 1
  fi

  echo "+ brew install alicicek/tap/llmpilot"
  brew install alicicek/tap/llmpilot

  echo
  echo "CLI installed. The menu bar app is one more command:"
  echo "  brew install --cask alicicek/tap/llmpilot"
  echo "Start here: llmpilot init"
}

main "$@"
