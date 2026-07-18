#!/bin/bash
# Local release: build, sign, notarize, staple, appcast, GitHub release.
# Runs entirely on the development machine — notarization waits are free
# here, and the Developer ID certificate and Sparkle EdDSA key both live
# in the login keychain, so no secret ever passes through CI or a shell
# argument.
#
# One-time setup (interactive, stores the app-specific password in your
# keychain; the script only ever references the profile name):
#   xcrun notarytool store-credentials llmpilot-notary \
#     --apple-id <apple-id> --team-id 6UUS5FCSJ3
#
# Usage: scripts/release-local.sh <tag>        e.g. v1.0.0 or test-v0.0.3
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=${1:?usage: release-local.sh <tag>}
VERSION="${TAG#test-}"; VERSION="${VERSION#v}"
BUILD_NUM=$(git rev-list --count HEAD)
IDENTITY="Developer ID Application"
PROFILE="llmpilot-notary"
# shellcheck source=scripts/sparkle-fetch.sh
. "$(dirname "$0")/sparkle-fetch.sh" # SPARKLE_VERSION + digest-verified fetch
DD="$(mktemp -d /tmp/llmpilot-release.XXXXXX)"
trap 'rm -rf "$DD"' EXIT

# The official app ships the Pro-enabled daemon (private engine compiled in via
# go.work + the -tags=pro build). A release without it would silently ship the
# free binary — fail loudly instead.
if [ ! -f go.work ] || [ ! -d ../llmpilot-pro ]; then
  echo "ERROR: an official release needs go.work + ../llmpilot-pro (the private" >&2
  echo "engine). Clone github.com/alicicek/llmpilot-pro next to this repo." >&2
  exit 1
fi

echo "== build (version $VERSION, build $BUILD_NUM) =="
(cd web && pnpm build) # the daemon binary embeds the real cockpit (go:embed)
xcodebuild -project macos/llmpilot.xcodeproj -scheme llmpilot \
  -configuration Release -derivedDataPath "$DD/dd" \
  CODE_SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM=6UUS5FCSJ3 \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  build | tail -2
APP="$DD/dd/Build/Products/Release/llmpilot.app"

echo "== bundle the Pro-enabled daemon (-tags=pro, go.work resolves the engine) =="
# From-source and Homebrew installs get the free binary on PATH; the official
# app carries this one and DaemonLauncher prefers it (macos DaemonLauncher.swift).
go build -tags=pro -trimpath -ldflags "-s -w -X main.version=$VERSION" \
  -o "$APP/Contents/Resources/llmpilot" ./cmd/llmpilot

echo "== sign Sparkle internals, then the app =="
SIGN() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
FW="$APP/Contents/Frameworks/Sparkle.framework"
SIGN "$FW/Versions/B/XPCServices/Downloader.xpc"
SIGN "$FW/Versions/B/XPCServices/Installer.xpc"
SIGN "$FW/Versions/B/Autoupdate"
SIGN "$FW/Versions/B/Updater.app"
SIGN "$FW"
SIGN "$APP/Contents/Resources/llmpilot" # the bundled daemon, before the app
SIGN "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== notarize (waits locally — costs nothing) =="
ditto -c -k --keepParent "$APP" "$DD/llmpilot.zip"
xcrun notarytool submit "$DD/llmpilot.zip" --keychain-profile "$PROFILE" \
  --wait --timeout 2h | tee "$DD/notary.log"
grep -q "status: Accepted" "$DD/notary.log"
xcrun stapler staple "$APP"
spctl -a -vv "$APP"

echo "== package + appcast =="
mkdir -p "$DD/updates"
ditto -c -k --keepParent "$APP" "$DD/updates/llmpilot-$VERSION.zip"
fetch_sparkle "$DD/sparkle" # digest-verified, freshly extracted every run
# generate_appcast signs with the EdDSA key from the login keychain.
"$DD/sparkle/bin/generate_appcast" \
  --link "https://github.com/alicicek/llmpilot" \
  --download-url-prefix "https://github.com/alicicek/llmpilot/releases/download/$TAG/" \
  "$DD/updates"

echo "== styled DMG (the website download; the zip stays for Sparkle + cask) =="
# create-dmg 1.3.0 via Homebrew (as-of 2026-07-18); it signs, notarizes with
# the same keychain profile, and staples the image. Built AFTER the appcast so
# generate_appcast never scans it. FIXED name: the site's /download redirect
# rides github's releases/latest/download/llmpilot.dmg alias.
command -v create-dmg >/dev/null || { echo "ERROR: create-dmg missing — brew install create-dmg" >&2; exit 1; }
mkdir -p "$DD/dmgroot"
ditto "$APP" "$DD/dmgroot/llmpilot.app"
create-dmg \
  --volname "llmpilot $VERSION" \
  --volicon scripts/dmg/volume.icns \
  --background scripts/dmg/background.tiff \
  --window-pos 200 140 --window-size 660 400 --icon-size 128 \
  --icon "llmpilot.app" 180 185 \
  --app-drop-link 480 185 \
  --codesign "$IDENTITY" \
  --notarize "$PROFILE" \
  "$DD/llmpilot.dmg" "$DD/dmgroot"
spctl -a -t open --context context:primary-signature -v "$DD/llmpilot.dmg"

echo "== tag + GitHub release =="
git tag -a "$TAG" -m "llmpilot $VERSION" 2>/dev/null || echo "tag $TAG exists locally"
git push origin "refs/tags/$TAG"
PRERELEASE=""
case "$TAG" in test-*) PRERELEASE="--prerelease" ;; esac
gh release create "$TAG" $PRERELEASE --title "llmpilot $VERSION" \
  --generate-notes "$DD/updates/llmpilot-$VERSION.zip" "$DD/updates/appcast.xml" \
  "$DD/llmpilot.dmg"

# CLI archives via goreleaser, then both tap files. goreleaser can no longer
# emit either tap artifact itself (brews: is deprecated and fails our
# `goreleaser check` gate; homebrew_casks: cannot checksum the externally
# notarized .app) — verified against the v2 docs 2026-07-17, see
# .goreleaser.yaml. test-v* prereleases stop here: nothing reaches the tap,
# and goreleaser would reject the non-semver tag anyway.
case "$TAG" in
  v*)
    echo "== CLI archives + checksums (goreleaser, appended to the release) =="
    export GITHUB_TOKEN="${GITHUB_TOKEN:-$(gh auth token)}"
    go run github.com/goreleaser/goreleaser/v2@v2.17.0 release --clean

    echo "== tap: formula (shas from dist/checksums.txt) + cask (sha from the notarized zip) =="
    ARM_SHA=$(awk '/llmpilot_'"$VERSION"'_darwin_arm64\.tar\.gz/{print $1}' dist/checksums.txt)
    AMD_SHA=$(awk '/llmpilot_'"$VERSION"'_darwin_amd64\.tar\.gz/{print $1}' dist/checksums.txt)
    APP_SHA=$(shasum -a 256 "$DD/updates/llmpilot-$VERSION.zip" | awk '{print $1}')
    if [ -z "$ARM_SHA" ] || [ -z "$AMD_SHA" ]; then
      echo "ERROR: archive checksums missing from dist/checksums.txt" >&2
      exit 1
    fi
    gh repo clone alicicek/homebrew-tap "$DD/tap" -- --depth 1
    mkdir -p "$DD/tap/Formula" "$DD/tap/Casks"
    cat > "$DD/tap/Formula/llmpilot.rb" <<EOF
# generated by scripts/release-local.sh for $TAG — do not edit by hand
class Llmpilot < Formula
  desc "Multi-account Claude Code companion — usage, switching, scheduling"
  homepage "https://llmpilot.dev"
  license "MIT"
  version "$VERSION"

  if Hardware::CPU.arm?
    url "https://github.com/alicicek/llmpilot/releases/download/$TAG/llmpilot_${VERSION}_darwin_arm64.tar.gz"
    sha256 "$ARM_SHA"
  else
    url "https://github.com/alicicek/llmpilot/releases/download/$TAG/llmpilot_${VERSION}_darwin_amd64.tar.gz"
    sha256 "$AMD_SHA"
  end

  def install
    bin.install "llmpilot"
  end

  test do
    system "#{bin}/llmpilot", "--version"
  end
end
EOF
    cat > "$DD/tap/Casks/llmpilot.rb" <<EOF
# generated by scripts/release-local.sh for $TAG — do not edit by hand
cask "llmpilot" do
  version "$VERSION"
  sha256 "$APP_SHA"

  url "https://github.com/alicicek/llmpilot/releases/download/v#{version}/llmpilot-#{version}.zip",
      verified: "github.com/alicicek/llmpilot/"
  name "llmpilot"
  desc "Multi-account Claude Code companion — the menu bar app"
  homepage "https://llmpilot.dev/"

  auto_updates true

  app "llmpilot.app"

  zap trash: "~/.llmpilot"
end
EOF
    git -C "$DD/tap" add Formula/llmpilot.rb Casks/llmpilot.rb
    git -C "$DD/tap" commit -m "llmpilot $VERSION"
    git -C "$DD/tap" push
    ;;
  *) echo "prerelease $TAG: skipped goreleaser + tap publish" ;;
esac
echo "RELEASE COMPLETE: $TAG (signed, notarized, stapled, appcast + tap published)"
