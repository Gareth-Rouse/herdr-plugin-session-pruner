#!/usr/bin/env bash
#
# Session Pruner -- a Herdr plugin.
#
# Herdr restores every workspace in session.json on start: each pane gets a
# fresh shell and, with session.resume_agents_on_restore, a resumed agent. A
# month of one-off workspaces therefore comes back forever. This plugin records
# when each workspace was last used, surfaces that age in the Spaces sidebar,
# and drops workspaces nobody has touched for a while.
#
# Subcommands:
#   startup       [[startup]] hook: adopt, prune (live mode), paint labels
#   touch         stamp the current workspace as used now, then refresh labels
#   sync          adopt unknown workspaces, forget dead ones, refresh labels
#   refresh       rewrite the sidebar token on every live workspace
#   prune-live    close cold workspaces through the running server
#   prune         filter cold workspaces out of the persisted session snapshot
#   prune-if-cold prune, but only when no server is running (launcher hook)
#   toggle-pin    pin/unpin the current workspace (pinned is never pruned)
#   report        print a workspace age table (used by the status popup pane)
#   config        print the effective configuration
#
# Requires: bash, jq. Optional: flock (falls back to a mkdir lock).

set -euo pipefail

pluginId="${HERDR_PLUGIN_ID:-garethrouse.session-pruner}"
herdrBin="${HERDR_BIN_PATH:-herdr}"
metadataSource="session-pruner"

configHome="${XDG_CONFIG_HOME:-$HOME/.config}"
stateHome="${XDG_STATE_HOME:-$HOME/.local/state}"
# HERDR_PLUGIN_*_DIR are only injected for plugin-launched commands; the
# launcher hook (prune-if-cold) runs outside Herdr and rebuilds the same paths.
configDir="${HERDR_PLUGIN_CONFIG_DIR:-$configHome/herdr/plugins/config/$pluginId}"
stateDir="${HERDR_PLUGIN_STATE_DIR:-$stateHome/herdr/plugins/$pluginId}"

die() {
  echo "session-pruner: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || die "jq is required but not on PATH"

# --------------------------------------------------------------------------
# Configuration
#
# $configDir/config.env holds KEY=VALUE lines. Real environment variables win,
# so a launcher hook or a Nix wrapper can override the file without editing it.
# --------------------------------------------------------------------------

loadConfig() {
  local file="$configDir/config.env" line key value
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in 'export '*) line="${line#export }" ;; esac
    key="${line%%=*}"
    [ "$key" != "$line" ] || continue
    case "$key" in SESSION_PRUNER_[A-Z_]*) ;; *) continue ;; esac
    # Already in the environment (or set by an earlier line): leave it alone.
    declare -p "$key" >/dev/null 2>&1 && continue
    value="${line#*=}"
    value="${value%"${value##*[![:space:]]}"}"
    case "$value" in
    '"'*'"' | "'"*"'") value="${value:1:${#value} - 2}" ;;
    esac
    printf -v "$key" '%s' "$value"
  done <"$file"
}

loadConfig

# off      -- track and label only, never remove anything
# live     -- the startup hook closes cold workspaces after restore (default:
#             works with a plain `herdr plugin install`, but restored panes do
#             briefly spawn before they are closed)
# snapshot -- nothing is closed at runtime; `prune-if-cold` filters the session
#             file before the server starts, so cold panes never spawn. Needs a
#             launcher hook (see README).
: "${SESSION_PRUNER_MODE:=live}"
# Workspaces untouched for longer than this are cold. 0 disables age pruning.
: "${SESSION_PRUNER_TTL_HOURS:=24}"
# Keep at most N workspaces, oldest-used dropped first. 0 = unlimited.
: "${SESSION_PRUNER_KEEP_MAX:=0}"
# Never prune below this many workspaces, however cold they are.
: "${SESSION_PRUNER_KEEP_MIN:=1}"
# Extended regex; a workspace whose name matches is never pruned. Matched
# against the workspace label (live) or custom_name/identity_cwd (snapshot).
: "${SESSION_PRUNER_PROTECT:=}"
# Keep workspaces whose agent is mid-task. Live mode only -- the session
# snapshot has no agent status.
: "${SESSION_PRUNER_PROTECT_BUSY_AGENTS:=1}"
# Report the age token to the Spaces sidebar.
: "${SESSION_PRUNER_LABELS:=1}"
: "${SESSION_PRUNER_LABEL_TOKEN:=last_used}"
: "${SESSION_PRUNER_PINNED_LABEL:=pin}"
# Log what would be pruned, prune nothing.
: "${SESSION_PRUNER_DRY_RUN:=0}"
: "${SESSION_PRUNER_SESSION_FILE:=$configHome/herdr/session.json}"
: "${SESSION_PRUNER_LEDGER:=$stateDir/lastUsed.json}"
: "${SESSION_PRUNER_PINS:=$stateDir/pins.json}"

sessionFile="$SESSION_PRUNER_SESSION_FILE"
historyFile="${sessionFile%.json}-history.json"
ledgerFile="$SESSION_PRUNER_LEDGER"
pinsFile="$SESSION_PRUNER_PINS"
labelCacheFile="$stateDir/labels.json"
lockFile="$stateDir/lock"

isTrue() {
  case "${1:-}" in 1 | true | yes | on) return 0 ;; *) return 1 ;; esac
}

log() {
  # Plugin command output is captured in `herdr plugin log`.
  echo "session-pruner: $*" >&2
}

# --------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------

# Every file this plugin owns is JSON, including Herdr's session snapshot. A
# failed jq upstream produces an empty pipe, so validate before the rename --
# an empty session.json would cost the user every workspace.
writeAtomic() {
  local target="$1" tmp
  mkdir -p "$(dirname "$target")"
  tmp="$target.tmp.$$"
  cat >"$tmp"
  if ! jq -e . "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    log "refusing to write invalid JSON to $target"
    return 1
  fi
  mv -f "$tmp" "$target"
}

readJson() {
  # $1 file, $2 fallback literal
  if [ -f "$1" ] && jq -e . "$1" >/dev/null 2>&1; then
    cat "$1"
  else
    printf '%s' "$2"
  fi
}

readLedger() { readJson "$ledgerFile" '{}'; }
readPins() { readJson "$pinsFile" '[]'; }

# Event hooks run concurrently; serialise every read-modify-write.
lockHeld=0

lock() {
  mkdir -p "$stateDir"
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$lockFile"
    flock 9
  else
    # macOS has no flock(1).
    local waited=0
    while ! mkdir "$lockFile.d" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
      [ "$waited" -lt 50 ] || break
    done
  fi
  lockHeld=1
}

unlock() {
  [ "$lockHeld" = 1 ] || return 0
  if command -v flock >/dev/null 2>&1; then
    exec 9>&-
  else
    rmdir "$lockFile.d" 2>/dev/null || true
  fi
  lockHeld=0
}

trap unlock EXIT

# --------------------------------------------------------------------------
# Herdr queries
# --------------------------------------------------------------------------

serverRunning() {
  case "$("$herdrBin" status server 2>/dev/null || true)" in
  *"status: running"*) return 0 ;;
  *) return 1 ;;
  esac
}

# [{id, name, seen, busy, focused}] for every live workspace.
liveWorkspaces() {
  local raw
  raw="$("$herdrBin" workspace list 2>/dev/null)" || return 1
  printf '%s' "$raw" | jq -c \
    --argjson ledger "$(readLedger)" \
    --argjson now "$(date +%s)" '
      [ (.result.workspaces // [])[]
        | { id: .workspace_id,
            name: (.label // ""),
            seen: ($ledger[.workspace_id] // $now),
            busy: ((.agent_status // "idle") | . != "idle" and . != "none" and . != "exited" and . != "unknown"),
            focused: (.focused // false) }
      ]' 2>/dev/null || return 1
}

# --------------------------------------------------------------------------
# Shared jq: age formatting and the prune plan
# --------------------------------------------------------------------------

# shellcheck disable=SC2016  # jq program text, not shell expansion
jqLib='
def ageLabel($s):
  if   $s < 60    then "now"
  elif $s < 3600  then "\(($s / 60)    | floor)m"
  elif $s < 86400 then "\(($s / 3600)  | floor)h"
  else                 "\(($s / 86400) | floor)d"
  end;

# Input: [{id, name, seen, busy, focused, ...}]. Output: the entries to drop,
# oldest first, with every input field preserved.
def prunePlan($now; $ttl; $keepMax; $keepMin; $protect; $pins; $protectBusy):
  [ .[] | . as $w | $w + {
      protected: (
        (($pins | index($w.id)) != null)
        or ($protect != "" and (($w.name // "") | test($protect)))
        or ($w.focused // false)
        or ($protectBusy and ($w.busy // false))
      ),
      age: ($now - $w.seen)
    } ] as $all
  | ([ $all[] | select(.protected | not) ] | sort_by(-.seen)) as $cands
  | ([ $all[] | select(.protected) ] | length) as $protectedCount
  | (if $keepMax > 0 then ($keepMax - $protectedCount) else -1 end) as $slots
  | [ range(0; ($cands | length)) as $i
      | $cands[$i]
      | . + { cold: ($ttl > 0 and (.age >= $ttl * 3600)),
              over: ($slots >= 0 and $i >= $slots) } ]
  | [ .[] | select(.cold or .over) ]
  | sort_by(.seen) as $drops
  | (($all | length) - $keepMin) as $maxDrops
  | if $maxDrops <= 0 then []
    else $drops[0 : (if ($drops | length) < $maxDrops then ($drops | length) else $maxDrops end)]
    end;
'

prunePlanArgs() {
  printf '%s' "--argjson now $(date +%s) \
    --argjson ttl ${SESSION_PRUNER_TTL_HOURS} \
    --argjson keepMax ${SESSION_PRUNER_KEEP_MAX} \
    --argjson keepMin ${SESSION_PRUNER_KEEP_MIN}"
}

# --------------------------------------------------------------------------
# Sidebar labels
# --------------------------------------------------------------------------

refresh() {
  isTrue "$SESSION_PRUNER_LABELS" || return 0
  local items desired changed id label
  items="$(liveWorkspaces)" || return 0
  [ "$(printf '%s' "$items" | jq 'length')" -gt 0 ] || return 0

  desired="$(printf '%s' "$items" | jq -c "$jqLib"'
      map(. as $w
          | { key: $w.id,
              value: (if ($pins | index($w.id)) != null then $pinned else ageLabel($now - $w.seen) end) })
      | from_entries' \
    --argjson now "$(date +%s)" \
    --argjson pins "$(readPins)" \
    --arg pinned "$SESSION_PRUNER_PINNED_LABEL")"

  # Labels are coarse, so almost every refresh is a no-op; only push the ones
  # that actually changed instead of one socket round trip per workspace.
  changed="$(printf '%s' "$desired" | jq -r \
    --argjson old "$(readJson "$labelCacheFile" '{}')" '
      to_entries[] | select($old[.key] != .value) | "\(.key)\t\(.value)"')"

  if [ -n "$changed" ]; then
    while IFS="$(printf '\t')" read -r id label; do
      [ -n "$id" ] || continue
      "$herdrBin" workspace report-metadata "$id" \
        --source "$metadataSource" \
        --token "$SESSION_PRUNER_LABEL_TOKEN=$label" >/dev/null 2>&1 || true
    done <<EOF
$changed
EOF
  fi

  # A stale label cache only costs a redundant metadata report next time.
  printf '%s' "$desired" | writeAtomic "$labelCacheFile" || true
}

# --------------------------------------------------------------------------
# Ledger maintenance
# --------------------------------------------------------------------------

touchWorkspace() {
  local id="${1:-${HERDR_WORKSPACE_ID:-}}"
  if [ -n "$id" ]; then
    lock
    readLedger |
      jq --arg id "$id" --argjson now "$(date +%s)" '.[$id] = $now' |
      writeAtomic "$ledgerFile"
    unlock
  fi
  refresh
}

# Workspaces restored before the ledger knew about them (first run, or created
# while the plugin was disabled) count as used now, so they survive the next
# prune. Workspaces that no longer exist leave the ledger.
syncWorkspaces() {
  local items ids
  items="$(liveWorkspaces)" || return 0
  ids="$(printf '%s' "$items" | jq -c 'map(.id)')"
  [ "$(printf '%s' "$ids" | jq 'length')" -gt 0 ] || return 0
  lock
  readLedger |
    jq --argjson ids "$ids" --argjson now "$(date +%s)" '
      . as $ledger
      | reduce $ids[] as $id ({}; .[$id] = ($ledger[$id] // $now))' |
    writeAtomic "$ledgerFile"
  readPins |
    jq -c --argjson ids "$ids" 'map(select(. as $p | $ids | index($p)))' |
    writeAtomic "$pinsFile"
  unlock
  refresh
}

forgetWorkspaces() {
  # stdin: one workspace id per line
  local ids
  ids="$(jq -R -s -c 'split("\n") | map(select(length > 0))')"
  [ "$(printf '%s' "$ids" | jq 'length')" -gt 0 ] || return 0
  lock
  readLedger |
    jq --argjson drop "$ids" 'delpaths([$drop[] | [.]])' |
    writeAtomic "$ledgerFile"
  unlock
}

# --------------------------------------------------------------------------
# Pruning
# --------------------------------------------------------------------------

# Close cold workspaces through the running server. Costs a spawn-then-close
# for every restored pane, but needs no launcher hook.
pruneLive() {
  local items drops ids
  items="$(liveWorkspaces)" || return 0
  # shellcheck disable=SC2046
  drops="$(printf '%s' "$items" | jq -c "$jqLib"'
      prunePlan($now; $ttl; $keepMax; $keepMin; $protect; $pins; $protectBusy)' \
    $(prunePlanArgs) \
    --arg protect "$SESSION_PRUNER_PROTECT" \
    --argjson pins "$(readPins)" \
    --argjson protectBusy "$(isTrue "$SESSION_PRUNER_PROTECT_BUSY_AGENTS" && echo true || echo false)")"

  ids="$(printf '%s' "$drops" | jq -r '.[] | .id')"
  [ -n "$ids" ] || return 0

  if isTrue "$SESSION_PRUNER_DRY_RUN"; then
    log "dry run, would close: $(printf '%s' "$drops" | jq -r '[.[] | "\(.id)(\(.name))"] | join(", ")')"
    return 0
  fi

  local id
  for id in $ids; do
    if "$herdrBin" workspace close "$id" >/dev/null 2>&1; then
      log "closed cold workspace $id"
    else
      log "could not close workspace $id"
    fi
  done
  printf '%s\n' "$ids" | forgetWorkspaces
  refresh
}

# Offline snapshot filter. Must not run against a live server: the server owns
# session.json in memory and would write our edits straight back out.
prune() {
  local plan total keep
  [ -f "$sessionFile" ] || return 0
  if serverRunning; then
    log "refusing to edit session.json while a server is running"
    return 0
  fi

  lock
  # shellcheck disable=SC2046
  plan="$(jq -c "$jqLib"'
      . as $s
      | [ range(0; ($s.workspaces | length))
          | { i: .,
              id: ($s.workspaces[.].id // ""),
              name: ($s.workspaces[.].custom_name // $s.workspaces[.].identity_cwd // ""),
              seen: ($ledger[$s.workspaces[.].id // ""] // $now),
              busy: false,
              focused: (. == $s.active) } ]
      | prunePlan($now; $ttl; $keepMax; $keepMin; $protect; $pins; false)
      | { drop: [ .[] | .i ], names: [ .[] | "\(.id)(\(.name))" ] }' \
    $(prunePlanArgs) \
    --arg protect "$SESSION_PRUNER_PROTECT" \
    --argjson pins "$(readPins)" \
    --argjson ledger "$(readLedger)" \
    "$sessionFile" 2>/dev/null)" || {
    unlock
    return 0
  }

  total="$(jq '.workspaces | length' "$sessionFile")"
  local dropCount
  dropCount="$(printf '%s' "$plan" | jq '.drop | length')"

  if isTrue "$SESSION_PRUNER_DRY_RUN"; then
    log "dry run, would drop $dropCount/$total: $(printf '%s' "$plan" | jq -r '.names | join(", ")')"
    unlock
    return 0
  fi

  # Always re-stamp the ledger: unknown workspaces were just adopted at $now.
  jq -c --argjson ledger "$(readLedger)" --argjson now "$(date +%s)" --argjson plan "$plan" '
      [ range(0; (.workspaces | length)) as $i
        | select(($plan.drop | index($i)) == null)
        | .workspaces[$i].id ]
      | map(select(. != null))
      | reduce .[] as $id ({}; .[$id] = ($ledger[$id] // $now))' \
    "$sessionFile" | writeAtomic "$ledgerFile"

  if [ "$dropCount" -eq 0 ]; then
    unlock
    return 0
  fi

  keep="$(jq -c -n --argjson total "$total" --argjson plan "$plan" '
    [ range(0; $total) as $i | select(($plan.drop | index($i)) == null) | $i ]')"

  jq -c --argjson keep "$keep" '
      .active as $active
      | .selected as $selected
      | .workspaces = [ $keep[] as $i | .workspaces[$i] ]
      | .active   = (if $active == null then null else (($keep | index($active)) // 0) end)
      | .selected = (($keep | index($selected)) // 0)' \
    "$sessionFile" | writeAtomic "$sessionFile"

  if [ -f "$historyFile" ]; then
    # session-history.json is positionally aligned with the session snapshot.
    jq -c --argjson keep "$keep" '.workspaces = [ $keep[] as $i | .workspaces[$i] ]' \
      "$historyFile" 2>/dev/null | writeAtomic "$historyFile" ||
      rm -f "$historyFile"
  fi

  log "dropped $dropCount/$total cold workspaces from the session snapshot"
  unlock
}

# --------------------------------------------------------------------------
# Pins, reporting, entry points
# --------------------------------------------------------------------------

togglePin() {
  local id="${1:-${HERDR_WORKSPACE_ID:-}}" state
  [ -n "$id" ] || die "no workspace in context"
  lock
  state="$(readPins | jq -r --arg id "$id" 'if index($id) then "unpinned" else "pinned" end')"
  readPins |
    jq -c --arg id "$id" 'if index($id) then map(select(. != $id)) else . + [$id] end' |
    writeAtomic "$pinsFile"
  unlock
  log "$id $state"
  # Force a repaint: the pin token replaces the age token.
  rm -f "$labelCacheFile"
  refresh
  "$herdrBin" notification show "Session Pruner" --body "workspace $id $state" >/dev/null 2>&1 || true
}

report() {
  local items
  printf 'Session Pruner  mode=%s  ttl=%sh  keep_max=%s  keep_min=%s%s\n\n' \
    "$SESSION_PRUNER_MODE" "$SESSION_PRUNER_TTL_HOURS" \
    "$SESSION_PRUNER_KEEP_MAX" "$SESSION_PRUNER_KEEP_MIN" \
    "$(isTrue "$SESSION_PRUNER_DRY_RUN" && echo '  (dry run)' || true)"

  if ! items="$(liveWorkspaces)"; then
    echo "no running Herdr server"
  else
    # shellcheck disable=SC2046
    printf '%s' "$items" | jq -r "$jqLib"'
        . as $ws
        | (prunePlan($now; $ttl; $keepMax; $keepMin; $protect; $pins; $protectBusy)
           | map(.id)) as $cold
        | ( ["ID", "WORKSPACE", "LAST USED", "EXPIRES", "STATE"],
            ( $ws
              | sort_by(-.seen)[]
              | . as $w
              | [ $w.id,
                  (($w.name // "")[0:24]),
                  ageLabel($now - $w.seen),
                  (if $ttl == 0 then "-"
                   elif ($pins | index($w.id)) != null then "never"
                   elif ($protect != "" and (($w.name // "") | test($protect))) then "never"
                   else ageLabel([($ttl * 3600) - ($now - $w.seen), 0] | max) end),
                  ( [ (if ($pins | index($w.id)) != null then "pinned" else empty end),
                      (if $w.focused then "focused" else empty end),
                      (if $w.busy then "busy" else empty end),
                      (if ($cold | index($w.id)) != null then "COLD" else empty end) ]
                    | join(",") | if . == "" then "-" else . end ) ] ) )
        | @tsv' \
      $(prunePlanArgs) \
      --arg protect "$SESSION_PRUNER_PROTECT" \
      --argjson pins "$(readPins)" \
      --argjson protectBusy "$(isTrue "$SESSION_PRUNER_PROTECT_BUSY_AGENTS" && echo true || echo false)" |
      awk -F'\t' '{ printf "%-6s %-24s %-10s %-10s %s\n", $1, $2, $3, $4, $5 }'
  fi

  if [ -t 0 ]; then
    printf '\nPress any key to close.'
    read -r -n 1 -s || true
    printf '\n'
  fi
}

showConfig() {
  local v
  for v in MODE TTL_HOURS KEEP_MAX KEEP_MIN PROTECT PROTECT_BUSY_AGENTS \
    LABELS LABEL_TOKEN PINNED_LABEL DRY_RUN SESSION_FILE LEDGER PINS; do
    eval "printf '%s=%s\n' \"SESSION_PRUNER_$v\" \"\${SESSION_PRUNER_$v}\""
  done
  printf 'config_dir=%s\nstate_dir=%s\n' "$configDir" "$stateDir"
}

startup() {
  case "$SESSION_PRUNER_MODE" in
  live) pruneLive ;;
  snapshot | off) ;;
  *) log "unknown SESSION_PRUNER_MODE '$SESSION_PRUNER_MODE', treating as off" ;;
  esac
  syncWorkspaces
}

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
startup) startup ;;
touch) touchWorkspace "${2:-}" ;;
sync) syncWorkspaces ;;
refresh) refresh ;;
prune-live) pruneLive ;;
prune) prune ;;
prune-if-cold)
  [ "$SESSION_PRUNER_MODE" = "snapshot" ] || exit 0
  serverRunning || prune
  ;;
toggle-pin) togglePin "${2:-}" ;;
report) report ;;
config) showConfig ;;
-h | --help | help | '') usage ;;
*)
  usage >&2
  exit 2
  ;;
esac
