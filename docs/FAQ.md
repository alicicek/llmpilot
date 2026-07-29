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

## What's the difference between adopting an account and moving it into the fleet?

Adopting leaves your sign-in exactly where it is. llmpilot records the account
and starts watching its limits, and nothing is removed from the folder it
signs in from. An account signed in from its own folder — anything other than
the shared `~/.claude` — stays **watched**: you see its usage, but llmpilot
will not switch to it, because switching means installing a sign-in into the
shared slot.

Moving into the fleet is what makes an account switchable, and it is the one
that changes your folders. llmpilot backs the sign-in up, installs it as a
fleet account, and then **retires the original folder** — the credential is
removed from it. A terminal that used `CLAUDE_CONFIG_DIR=<that folder>` will
need to sign in again. The app asks you to confirm and says which folder is
affected before it does any of this.

Two copies of one sign-in is the reason the move exists: refreshing one copy
invalidates the other, so while both exist llmpilot refuses to refresh that
account and its numbers drift. `llmpilot doctor` names this when it sees it.

## The daemon won't start, or nothing looks live

Everything else reads from the daemon, so when it is down every surface goes
quiet at once. Work through it in this order:

1. `llmpilot doctor` — it checks the daemon, the login item, and the install,
   and says what is wrong. It only looks; it never writes.
2. `llmpilot daemon status` to see whether launchd has the job at all.
3. If it is not installed: `llmpilot daemon install`, then load it with the
   `launchctl bootstrap` line that command prints. If you use the menu bar
   app instead, its **Start daemon** button does the same thing.
4. To watch it fail in the foreground, run `llmpilot daemon run` — errors go
   to the terminal instead of the log.
5. If macOS is holding the login item for approval, the app says so and links
   you to System Settings → General → Login Items & Extensions; approve
   llmpilot there and start it again.

If the app updated recently and the numbers look frozen, the daemon may still
be running the previous build — it is a separate background job, so replacing
the app does not replace it. Quitting and reopening the app fixes this from
1.2.3 onward, because it checks on launch and restarts the daemon itself. On
an older build, or if it does not clear, restart the daemon by hand:

```
launchctl kickstart -k gui/$(id -u)/dev.llmpilot.daemon
```

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

**Stop the background daemon first.** Uninstalling the binary without this
leaves a launchd job pointing at a file that no longer exists:

```
launchctl bootout gui/$(id -u)/dev.llmpilot.daemon
```

That is enough if you installed the CLI with `brew install`. Also delete the
launch agent it wrote, or launchd will load it again at your next login:

```
rm -f ~/Library/LaunchAgents/dev.llmpilot.daemon.plist
```

If you installed the menu bar app, it registers the daemon through macOS
rather than that file, so there is nothing to delete — but after removing the
app, check **Settings → General → Login Items & Extensions** and remove any
llmpilot entry still listed there.

If you wired up the statusline, revert it **while the binary still exists**:

```
llmpilot statusline uninstall
```

It removes only llmpilot's own line from `~/.claude/settings.json` — a
statusline it replaced is put back, and one it didn't write is left alone.
Already deleted the binary? Open `~/.claude/settings.json` and delete the
`"statusLine"` block yourself; until you do, Claude Code keeps trying to run
a command that no longer exists.

Then uninstall: `brew uninstall llmpilot` (and `brew uninstall --cask
llmpilot` for the app), and remove local state with `rm -rf ~/.llmpilot`.

Three things live in your login keychain and outlast an uninstall. Credential
backups and kept sign-ins are under `llmpilot-backups`, setup tokens under
`llmpilot-setup-tokens`, and your Pro licence under
`dev.llmpilot.entitlement`. Delete them in Keychain Access if you want them
gone — leaving the licence costs nothing, and if you reinstall later you can
recover it by email anyway.

The sign-in active in `~/.claude` is left alone. One caveat: if you used
"move into the fleet", that sign-in's original folder was retired at the time
of the move — sign in from that folder again to recreate it.
