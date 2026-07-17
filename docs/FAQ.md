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

No. It uses the OAuth credential Claude Code already stored in your Keychain when
you logged in. There is no separate login, no API key, and nothing to paste.

## Why did macOS ask to access the Keychain?

The first time a given binary reads the Claude credential, macOS asks once.
Click **Always Allow** and it won't ask again for that binary. Homebrew installs
a stable binary path so the grant sticks; a source build run with `go run`
changes paths and re-prompts, so use `make build` there.

## Do my tokens or usage ever leave my machine?

Tokens: never. Usage numbers: only in the sense that reading them requires
calling Anthropic's own usage endpoint with your own token — the same call
Claude Code makes. Nothing is sent to any llmpilot server. There is no
telemetry. Cache files hold percentages and reset times only.

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

## Why might usage or a switch stop working?

The usage endpoint, the OAuth token endpoint, and Claude Code's Keychain and
config layout are undocumented and can change. llmpilot keeps that knowledge in
small adapters with a delegation fallback, but a Claude Code change can still
break a feature until an update lands. When a login can't be refreshed, the
dashboard says so plainly and points you at re-authenticating.

## Is Windows or Linux supported?

Not yet — macOS only for now. The core is portable Go; the menu bar, Keychain,
and wake scheduling are macOS-specific.

## How do I remove it?

`brew uninstall llmpilot` (and `--cask llmpilot` for the app). Remove local state
with `rm -rf ~/.llmpilot`. llmpilot never modified your Claude login beyond
switching which account is active, and uninstalling leaves that account as-is.
