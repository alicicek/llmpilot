# Sourced by release-local.sh and sparkle-keys.sh — the ONE place the Sparkle
# tooling is pinned and verified. Both consumers run beside the login-keychain
# signing keys, so a substituted archive is code execution in the signing
# context: nothing extracts, and no binary runs, before the digest matches.
#
# SPARKLE_SHA256 is the digest of the official release asset, computed from
# two independent downloads on 2026-07-15. Bumping SPARKLE_VERSION means
# recomputing it (shasum -a 256) and keeping macos/project.yml in lockstep.

SPARKLE_VERSION=2.9.4 # keep in lockstep with macos/project.yml
SPARKLE_SHA256=ce89daf967db1e1893ed3ebd67575ed82d3902563e3191ca92aaec9164fbdef9

# fetch_sparkle <destdir> — put a VERIFIED Sparkle bin/ under <destdir>.
# The tarball caches under ~/Library/Caches/llmpilot, but the cache is never
# trusted: the digest is re-verified on every run (a mismatch deletes the file
# and aborts), and binaries are always freshly extracted from the verified
# archive — a previously extracted tree is writable and proves nothing.
fetch_sparkle() {
  local dest=$1
  local cache_dir="$HOME/Library/Caches/llmpilot"
  local tarball="$cache_dir/Sparkle-$SPARKLE_VERSION.tar.xz"
  mkdir -p "$cache_dir" "$dest"
  if [ ! -f "$tarball" ]; then
    curl -fsSL --remove-on-error -o "$tarball" \
      "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
  fi
  if ! echo "$SPARKLE_SHA256  $tarball" | shasum -a 256 -c - >/dev/null 2>&1; then
    rm -f "$tarball"
    echo "ERROR: Sparkle-$SPARKLE_VERSION.tar.xz does not match the pinned digest" >&2
    echo "       ($SPARKLE_SHA256). The cached/downloaded archive was deleted;" >&2
    echo "       re-run to download fresh. If it fails again, verify upstream" >&2
    echo "       before touching the pin." >&2
    return 1
  fi
  tar -xJf "$tarball" -C "$dest"
}
