// The daemon guards license reveal/mutation behind a per-run install token
// (internal/daemon/auth.go). Trusted launchers — `llmpilot open` and the menu
// bar — append it as a URL fragment, which never rides a request or Referer;
// initAuth moves it into sessionStorage and strips it from the address bar on
// boot. Opened without a token, the cockpit still renders read-only views;
// license actions answer 401 with copy pointing at the trusted launchers.
// Lazy + window-guarded: api.ts is imported by Node-side specs too.

const KEY = "llmpilot.installToken";

let token: string | null = null;
let initialized = false;

function readToken(): string | null {
  if (typeof window === "undefined") return null;
  const m = /(?:^|[#&])token=([0-9a-f]+)/.exec(window.location.hash);
  if (m) {
    try {
      sessionStorage.setItem(KEY, m[1]);
    } catch {
      // Storage can be unavailable (private mode); the in-memory copy still
      // covers this page's lifetime.
    }
    history.replaceState(null, "", window.location.pathname + window.location.search);
    return m[1];
  }
  try {
    return sessionStorage.getItem(KEY);
  } catch {
    return null;
  }
}

/** Capture the fragment token and clean the address bar; called at boot. */
export function initAuth(): void {
  if (initialized) return;
  initialized = true;
  token = readToken();
}

/** Headers proving install-scoped authority; empty when no token arrived. */
export function authHeaders(): Record<string, string> {
  initAuth();
  return token ? { Authorization: `Bearer ${token}` } : {};
}
