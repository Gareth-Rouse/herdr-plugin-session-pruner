# Session Pruner

A [Herdr](https://herdr.dev) plugin that stops your restored session growing forever.

Herdr restores every workspace in `session.json` on start: each pane gets a fresh shell and, with `session.resume_agents_on_restore`, a resumed agent.
A month of one-off workspaces therefore comes back every single time.

Session Pruner records when each workspace was last used, shows that age in the Spaces sidebar, and drops the ones nobody has touched in a while.

```
w1Y  .omp                9h        in 15h     -
w23  nixos-config        2m        in 23h     focused
w2A  scratch             3d        expired    COLD
w28  ops                 5d        never      pinned
```

## Install

```sh
herdr plugin install Gareth-Rouse/herdr-plugin-session-pruner
```

Requires `bash` and `jq` on `PATH`. `flock` is used when present; without it (macOS) the plugin falls back to a `mkdir` lock.

Nothing is pruned until a workspace has gone `SESSION_PRUNER_TTL_HOURS` (default 24) without being focused, and the active workspace, busy agents and pinned workspaces are never pruned.
Set `SESSION_PRUNER_MODE=off` first if you would rather watch the ages for a few days before letting it remove anything.

## Configuration

Every setting is a `KEY=VALUE` line in `config.env` inside the plugin config directory:

```sh
$EDITOR "$(herdr plugin config-dir garethrouse.session-pruner)/config.env"
```

Real environment variables override the file, so a launcher wrapper or a Nix module can set them without editing user state.
`herdr plugin action invoke garethrouse.session-pruner.prune-now` is enough to apply a change; nothing needs restarting.

| Key | Default | Meaning |
| --- | --- | --- |
| `SESSION_PRUNER_MODE` | `live` | `live` closes cold workspaces from the startup hook. `snapshot` edits `session.json` before the server starts (see below). `off` only tracks and labels. |
| `SESSION_PRUNER_TTL_HOURS` | `24` | A workspace is cold after this long without focus. `0` disables age-based pruning. |
| `SESSION_PRUNER_KEEP_MAX` | `0` | Keep at most this many workspaces, oldest-used dropped first. `0` is unlimited. |
| `SESSION_PRUNER_KEEP_MIN` | `1` | Never prune below this many workspaces, however cold they are. |
| `SESSION_PRUNER_PROTECT` | empty | Extended regex. A matching workspace is never pruned; matched against the workspace label (live) or `custom_name`, falling back to `identity_cwd` (snapshot). |
| `SESSION_PRUNER_PROTECT_BUSY_AGENTS` | `1` | Keep workspaces whose agent is mid-task. Live mode only: the session snapshot carries no agent status. |
| `SESSION_PRUNER_LABELS` | `1` | Report the age token to the Spaces sidebar. |
| `SESSION_PRUNER_LABEL_TOKEN` | `last_used` | Sidebar token name. |
| `SESSION_PRUNER_PINNED_LABEL` | `pin` | Token value shown for a pinned workspace. |
| `SESSION_PRUNER_DRY_RUN` | `0` | Log what would be pruned and prune nothing. |
| `SESSION_PRUNER_SESSION_FILE` | `$XDG_CONFIG_HOME/herdr/session.json` | Session snapshot to filter in `snapshot` mode. |
| `SESSION_PRUNER_LEDGER` | `<state dir>/lastUsed.json` | Last-use ledger. |
| `SESSION_PRUNER_PINS` | `<state dir>/pins.json` | Pinned workspace ids. |

`config.example.env` is a copyable starting point.

## Showing the age in the sidebar

The plugin reports a `$last_used` metadata token per workspace. Add it to a Spaces sidebar row in `config.toml`:

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace", { token = "$last_used", dim = true }],
  ["branch", "git_status"],
]
```

Labels are coarse (`now`, `12m`, `9h`, `3d`), so a refresh usually changes nothing; only workspaces whose label actually changed are pushed back to Herdr.

## Actions

| Action | Purpose |
| --- | --- |
| `garethrouse.session-pruner.toggle-pin` | Pin/unpin the current workspace. Pinned workspaces are never pruned and show the pin token. |
| `garethrouse.session-pruner.prune-now` | Prune cold workspaces immediately. |

Bind them in `config.toml`:

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "garethrouse.session-pruner.toggle-pin"
description = "pin workspace"
```

The `status` pane entrypoint opens a popup with the full age table:

```sh
herdr plugin pane open --plugin garethrouse.session-pruner --entrypoint status
```

## live vs snapshot mode

Herdr has no pre-restore hook, so there are two ways to remove a cold workspace and they trade off differently.

**`live` (default)** — the `[[startup]]` hook runs once the session is restored and the socket is up, then closes cold workspaces through the normal `workspace close` API.
Works with a plain `herdr plugin install`, but every restored pane spawns a shell (and possibly resumes an agent) a moment before it is closed.

**`snapshot`** — nothing is closed at runtime.
Instead the cold workspaces are filtered out of `session.json` *before* the server reads it, so their panes never spawn at all.
That needs a hook in whatever launches Herdr, because a plugin cannot run before the server:

```sh
# ~/.bashrc, ~/.zshrc, or a launcher script.
# Only a bare `herdr [flags]` or `herdr server` can start a server; every other
# invocation (`herdr pane send-text`, agent state reporters, ...) is a socket
# client and must not pay for the check.
herdr() {
  case "${1-}" in
    ''|-*|server)
      bash ~/path/to/herdr-plugin-session-pruner/sessionPruner.sh prune-if-cold || true
      ;;
  esac
  command herdr "$@"
}
```

`prune-if-cold` is a no-op unless `SESSION_PRUNER_MODE=snapshot`, and it refuses to touch `session.json` while a server is running — the server owns that file in memory and would write your edits straight back out.

A Nix wrapper does the same thing declaratively:

```nix
pkgs.symlinkJoin {
  name = "herdr-pruned";
  paths = [ pkgs.herdr ];
  nativeBuildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/herdr --run '
      case "''${1-}" in ""|-*|server)
        ${pluginSrc}/sessionPruner.sh prune-if-cold || true ;;
      esac'
  '';
}
```

## How "used" is decided

A workspace is stamped as used when it, or one of its panes, is focused.
Background agent output deliberately does not count: hooking `pane.agent_status_changed` would spawn a process every few seconds per agent.
Long-running background work is protected at prune time instead, through `SESSION_PRUNER_PROTECT_BUSY_AGENTS` (live mode) and pinning.

Workspaces the ledger has never seen — first run, or created while the plugin was disabled — are adopted as "used now", so enabling the plugin never prunes anything on its first start.

## CLI

`sessionPruner.sh` is a plain script; every entrypoint can be run by hand.

```
startup       adopt, prune (live mode), paint labels
touch         stamp the current workspace as used now
sync          adopt unknown workspaces, forget dead ones
refresh       rewrite the sidebar token on every live workspace
prune-live    close cold workspaces through the running server
prune         filter cold workspaces out of the persisted session snapshot
prune-if-cold prune, but only when no server is running
toggle-pin    pin/unpin the current workspace
report        print the workspace age table
config        print the effective configuration
```

## Tests

```sh
bash tests/pruneTest.sh
```

No Herdr server is involved: the snapshot tests drive a synthetic `session.json`, and the live tests point `HERDR_BIN_PATH` at a stub.

## License

MIT
