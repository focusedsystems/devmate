# DevMate

A public Swift package that gives a macOS app Development and Projects tabs.
Everything here is public and permanent, commit messages and pull requests
included.

## Rules

- **Nothing app-specific.** No organisation or owner names, hostnames, tenant or
  directory ids, staff names, private repository names, work item ids, clone
  layouts or estate detail, in code, tests, comments, commits or pull requests.
  Apps supply these as configuration. Fixtures use `example` names only.
- **No dependency on AgentsMate.** Apps pin AgentsMate by revision, and a second
  pin here would conflict at resolution. Each app adapts DevMate to its lane
  store.
- **The registry is read-only.** DevMate reads
  `~/.config/agent-apps/repos/<bundle id>.json` and never writes it. A reader
  refuses a schema version it does not know.
- **Raw issue text never reaches a lane.** Only the safety layer can build a
  `SafeLaneRequest`. Do not add a public initializer, `Decodable`, or a way to
  submit a prompt automatically.
- **Pull request lanes are always a plain shell.** Checking out a pull request
  never starts an agent, for any author. Starting one is a separate step the
  person takes, after seeing any risk findings. Do not add an agent-start path
  to the checkout API.
- **Swift 6 language mode, macOS 27 minimum.** UI follows the mac-arsed-mac-app
  conventions.

## Working

Work in a worktree at `./.worktrees/<name>` off `origin/main`. Before a pull
request, run:

```bash
swift build && swift test && python3 scripts/zone_check.py
```

Land changes through a pull request; main is never pushed directly. Apps follow
main through their own `devmate-sync` workflow, so a breaking API change needs
the matching change in each app.
