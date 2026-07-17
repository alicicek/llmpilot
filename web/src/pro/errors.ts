// One place maps licensing refusal codes to copy. VOICE.md register: say
// what happened, then what to do next — never a bare code, never blame.

export function licenseErrorCopy(code: string | undefined): string | null {
  switch (code) {
    case "seat_limit_reached":
      return "Seat limit reached — this license is already on its maximum number of Macs. Restore by email to move Pro to this one.";
    case "trial_email_used":
      return "That email already used the free trial. Pick a paid plan to turn the autopilot on.";
    case "install_not_activated":
      return "This Mac is not activated for that license. Restore by email to activate it here.";
    case "auth_required":
      return "This page opened without its session token. Reopen the cockpit from the menu bar, or run `llmpilot open`.";
    default:
      return null;
  }
}
