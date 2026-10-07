// The daemon guards every /v1 route — reads and mutations — behind a per-run
// token (internal/daemon/auth.go); only the static cockpit files are open.
// `llmpilot open` appends the token as a URL fragment, which never rides a
// request or Referer; initAuth moves it into sessionStorage and strips it from
// the address bar on boot. Opened without a token, the cockpit has nothing to
// show: reads answer 401 auth_required and the boot screen says how to reopen.
// Lazy + window-guarded so importing api.ts never touches window at load.

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
