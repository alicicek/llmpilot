# FAQ

## Is this allowed under Anthropic's terms?

It's a gray zone, and you should decide informed. Anthropic's policy (as of
February 2026) limits the OAuth credential to *"ordinary use of Claude Code and
native Anthropic applications."* The related ban on using it *"on behalf of
their users"* is aimed at hosted SaaS proxies — a local, personal tool that only
ever touches your own machine is not addressed either way. Running multiple Max
plans and switching between them is not explicitly prohibited, but some
multi-account users have reported automated account actions.

llmpilot never sends your credentials off your machine and adds no usage of its
own beyond reading what Claude Code already does. That does not make the gray
zone go away. If that risk isn't one you want to take, this isn't the tool for
you — and that's a fair call.

## Does it need my Claude password or an API key?

No. It uses the OAuth credential Claude Code already stored in your Keychain
when you logged in. There is no API key. Adding a new account happens on
Anthropic's own sign-in page — either through `claude` in a terminal or from
inside the app — and llmpilot never sees your password either way.

## Why did macOS ask to access the Keychain?

The first time a given binary reads the Claude credential, macOS asks once.
Click **Always Allow** and it won't ask again for that binary. Homebrew installs
a stable binary path so the grant sticks; a source build run with `go run`
changes paths and re-prompts, so use `make build` there.

## Do my tokens or usage ever leave my machine?

Tokens: never. Usage numbers: only in the sense that reading them requires
calling Anthropic's own usage endpoint with your own token — the same call
Claude Code makes. No usage data and no telemetry is ever sent to an
llmpilot server. If you buy Pro, your licence re-validates with llmpilot's
licensing worker about once a week: that request carries a licence id and a
random install id, and nothing else. Cache files hold percentages and reset
times only.

## What's free and what's Pro?

Free forever: live usage for every account, manual switching, the cockpit, the
statusline, and analytics. Pro (a one-time £9.99 / $12.99, not a subscription):
automatic switching, window scheduling, and waking the Mac for scheduled starts.
Official signed builds include Pro; a build you compile yourself is the free app.

## Will scheduled window starts work while my Mac is asleep?

Only if the Mac is awake at the scheduled time or you've granted the one-time
wake permission. With permission, llmpilot arms a `pmset` wake for the next
scheduled start. Without it, the start fires on the next wake instead — which may
be late — and llmpilot tells you so rather than pretending it fired on time.

## What happens if my plan changes or a window is late?

llmpilot renders whatever the usage endpoint returns, including bucket kinds it
has never seen. If Anthropic changes plans, models, or credit rules, the
dashboard shows the new shape instead of an error. A scheduled start only *opens*
a window when none is active; it never shifts a window you're already in.

## Does llmpilot refresh my tokens in the background?

No. There is no background refresh loop — an earlier version had one, and it
turned out to be the fastest way to get accounts rate-limited. llmpilot
refreshes a login only when something needs it: about 10 minutes before a
switch (yours or the autopilot's), when the autopilot revives a stale
account, or when you sign in from the app. Refreshes are capped at 2 attempts
per account per rolling
24 hours, and a single rate-limit answer from the token endpoint pauses all
refreshes for 24 hours. An account that goes stale in the meantime is shown
stale — last-known numbers, marked — never silently wrong.

## Why might usage or a switch stop working?

The usage endpoint, the OAuth token endpoint, and Claude Code's Keychain and
config layout are undocumented and can change. llmpilot keeps that knowledge in
small adapters with a delegation fallback, but a Claude Code change can still
break a feature until an update lands. When a login can't be refreshed, the
dashboard says so plainly and points you at re-authenticating. For anything
else, `llmpilot doctor` checks the fleet, the sign-ins on the Mac, the refresh
budget, and the install, and names what is wrong — it only looks, it never
writes.

## Is Windows or Linux supported?

Not yet — macOS only for now. The core is portable Go; the menu bar, Keychain,
and wake scheduling are macOS-specific.

## How do I remove it?

`brew uninstall llmpilot` (and `--cask llmpilot` for the app). Remove local
state with `rm -rf ~/.llmpilot`. Credential backups, kept foreign sign-ins,
and setup tokens live in your login keychain under the `llmpilot-backups` and
`llmpilot-setup-tokens` services — delete those items in Keychain Access if
you want them gone too. The sign-in active in `~/.claude` is left as-is. One
caveat: if you used "move into the fleet", the moved sign-in's original
folder was retired at move time (that is what the move does, after backing
up) — sign in from that folder again to recreate it.
