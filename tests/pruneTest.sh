#!/usr/bin/env bash
#
# Offline tests for sessionPruner.sh. No Herdr server is involved: the snapshot
# tests drive a synthetic session.json, and the live tests point HERDR_BIN_PATH
# at a stub that serves canned `workspace list` output and records every
# `workspace close`.
#
# Usage: bash tests/pruneTest.sh

# shellcheck disable=SC2030,SC2031  # subshell exports are the point: each case is isolated
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
script="$here/../sessionPruner.sh"
failures=0
now="$(date +%s)"

ok() { printf '  ok   %s\n' "$1"; }
bad() {
  printf '  FAIL %s\n    %s\n' "$1" "${2:-}"
  failures=$((failures + 1))
}

assertEq() {
  # name, expected, actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

# Five workspaces; ages come from the ledger. active/selected point at w5, the
# newest, unless a test overrides them: the active workspace is never pruned.
makeSession() {
  jq -n '{
    version: 3,
    active: 4,
    selected: 4,
    collapsed_space_keys: [],
    workspaces: [
      { id: "w1", custom_name: "alpha",  identity_cwd: "/p/alpha",  tabs: [] },
      { id: "w2", custom_name: null,     identity_cwd: "/p/beta",   tabs: [] },
      { id: "w3", custom_name: "ops",    identity_cwd: "/p/ops",    tabs: [] },
      { id: "w4", custom_name: "delta",  identity_cwd: "/p/delta",  tabs: [] },
      { id: "w5", custom_name: "epsilon",identity_cwd: "/p/eps",    tabs: [] }
    ]
  }'
}

makeHistory() {
  jq -n '{ workspaces: [ "h1", "h2", "h3", "h4", "h5" ] }'
}

# Ages in hours, oldest first: w1 100h, w2 50h, w3 48h, w4 1h, w5 0h.
makeLedger() {
  jq -n --argjson now "$now" '{
    w1: ($now - 100 * 3600),
    w2: ($now -  50 * 3600),
    w3: ($now -  48 * 3600),
    w4: ($now -   1 * 3600),
    w5: $now
  }'
}

# A fresh sandbox: $box/session.json, $box/session-history.json, ledger, pins.
newBox() {
  local box
  box="$(mktemp -d "${TMPDIR:-/tmp}/sessionPrunerTest.XXXXXX")"
  makeSession >"$box/session.json"
  makeHistory >"$box/session-history.json"
  mkdir -p "$box/state"
  makeLedger >"$box/state/lastUsed.json"
  printf '[]' >"$box/state/pins.json"
  printf '%s' "$box"
}

# A stub herdr. `status server` answers from $STUB_SERVER, `workspace list`
# echoes $STUB_WORKSPACES, `workspace close` appends to $box/closed.
makeStub() {
  local box="$1"
  cat >"$box/herdr" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
"status server")
  echo "status: ${STUB_SERVER:-stopped}"
  ;;
"workspace list")
  if [ -n "${STUB_WORKSPACES:-}" ]; then
    printf '%s' "$STUB_WORKSPACES"
  else
    printf '{"result":{"workspaces":[]}}'
  fi
  ;;
"workspace close")
  echo "$3" >>"$STUB_BOX/closed"
  ;;
"workspace report-metadata")
  echo "$3 $7" >>"$STUB_BOX/metadata"
  ;;
*) ;;
esac
STUB
  chmod +x "$box/herdr"
}

run() {
  # run <box> <args...>; config comes from SESSION_PRUNER_* already exported
  local box="$1"
  shift
  HERDR_BIN_PATH="$box/herdr" \
    STUB_BOX="$box" \
    HERDR_PLUGIN_STATE_DIR="$box/state" \
    HERDR_PLUGIN_CONFIG_DIR="$box/config" \
    SESSION_PRUNER_SESSION_FILE="$box/session.json" \
    bash "$script" "$@" || true
}

ids() { jq -r '[.workspaces[].id] | join(",")' "$1/session.json"; }

# --------------------------------------------------------------------------
# Snapshot pruning
# --------------------------------------------------------------------------

echo "snapshot prune"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_KEEP_MIN=1
  run "$box" prune
)
assertEq "drops workspaces past the TTL" "w4,w5" "$(ids "$box")"
assertEq "remaps active onto the kept slice" "1" "$(jq -r .active "$box/session.json")"
assertEq "remaps selected onto the kept slice" "1" "$(jq -r .selected "$box/session.json")"
assertEq "keeps history positionally aligned" "h4,h5" \
  "$(jq -r '.workspaces | join(",")' "$box/session-history.json")"
assertEq "forgets pruned ids in the ledger" "w4,w5" \
  "$(jq -r '[keys[]] | join(",")' "$box/state/lastUsed.json")"
rm -rf "$box"
box="$(newBox)"
makeStub "$box"
jq '.active = 0 | .selected = 0' "$box/session.json" >"$box/s" && mv "$box/s" "$box/session.json"
(
  export SESSION_PRUNER_TTL_HOURS=24
  run "$box" prune
)
assertEq "the active workspace is never pruned" "w1,w4,w5" "$(ids "$box")"
rm -rf "$box"



box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=0
  run "$box" prune
)
assertEq "ttl 0 disables age pruning" "w1,w2,w3,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
printf '["w1"]' >"$box/state/pins.json"
(
  export SESSION_PRUNER_TTL_HOURS=24
  run "$box" prune
)
assertEq "a pinned workspace survives" "w1,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_PROTECT='^ops$'
  run "$box" prune
)
assertEq "protect matches custom_name" "w3,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_PROTECT='beta'
  run "$box" prune
)
assertEq "protect falls back to identity_cwd" "w2,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=1 SESSION_PRUNER_KEEP_MIN=4
  run "$box" prune
)
assertEq "keep_min floors the drop count, oldest first" "w2,w3,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=0 SESSION_PRUNER_KEEP_MAX=2
  run "$box" prune
)
assertEq "keep_max trims to the most recently used" "w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_DRY_RUN=1
  run "$box" prune
)
assertEq "dry run changes nothing" "w1,w2,w3,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 STUB_SERVER=running
  run "$box" prune
)
assertEq "refuses to edit a live session file" "w1,w2,w3,w4,w5" "$(ids "$box")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
printf '{}' >"$box/state/lastUsed.json"
(
  export SESSION_PRUNER_TTL_HOURS=24
  run "$box" prune
)
assertEq "unknown workspaces are adopted, not pruned" "w1,w2,w3,w4,w5" "$(ids "$box")"
assertEq "adoption stamps the whole ledger" "5" \
  "$(jq -r 'keys | length' "$box/state/lastUsed.json")"
rm -rf "$box"

# --------------------------------------------------------------------------
# Live pruning
# --------------------------------------------------------------------------

echo "live prune"

liveWorkspaces() {
  jq -n --argjson now "$now" '{ result: { workspaces: [
    { workspace_id: "w1", label: "alpha", agent_status: "idle",    focused: false },
    { workspace_id: "w2", label: "beta",  agent_status: "working", focused: false },
    { workspace_id: "w3", label: "ops",   agent_status: "idle",    focused: false },
    { workspace_id: "w5", label: "eps",   agent_status: "idle",    focused: true  }
  ] } }'
}

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_LABELS=0
  export STUB_SERVER=running
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" prune-live 2>/dev/null
)
assertEq "closes cold, spares busy and focused" "w1,w3" \
  "$(tr '\n' ',' <"$box/closed" | sed 's/,$//')"
assertEq "closed workspaces leave the ledger" "w2,w4,w5" \
  "$(jq -r '[keys[]] | join(",")' "$box/state/lastUsed.json")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_LABELS=0
  export SESSION_PRUNER_PROTECT_BUSY_AGENTS=0 STUB_SERVER=running
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" prune-live 2>/dev/null
)
assertEq "protect_busy_agents=0 closes the busy workspace too" "w1,w2,w3" \
  "$(tr '\n' ',' <"$box/closed" | sed 's/,$//')"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 SESSION_PRUNER_LABELS=0 SESSION_PRUNER_DRY_RUN=1
  export STUB_SERVER=running
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" prune-live 2>/dev/null
)
closedCount() {
  if [ -f "$1/closed" ]; then
    wc -l <"$1/closed" | tr -d ' '
  else
    echo 0
  fi
}
assertEq "live dry run closes nothing" "0" "$(closedCount "$box")"
rm -rf "$box"

# --------------------------------------------------------------------------
# Focus dwell
# --------------------------------------------------------------------------

echo "focus dwell"

# w1 (100h) and w3 (48h) are both cold; w3 ends up focused.
focusedOn() {
  jq -n --arg f "$1" '{ result: { workspaces: [
    { workspace_id: "w1", label: "alpha", agent_status: "idle", focused: ($f == "w1") },
    { workspace_id: "w3", label: "ops",   agent_status: "idle", focused: ($f == "w3") }
  ] } }'
}
ageOf() { jq -r --arg id "$2" --argjson now "$(date +%s)" '$now - .[$id]' "$1/state/lastUsed.json"; }

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_DWELL_SECONDS=1 SESSION_PRUNER_LABELS=0 STUB_SERVER=running
  STUB_WORKSPACES="$(focusedOn w3)"
  export STUB_WORKSPACES
  run "$box" focus w1
  run "$box" focus w3
)
assertEq "focus does not stamp before the dwell" "true" "$(jq "$(ageOf "$box" w3) > 3600" -n)"
sleep 2
assertEq "a swept-past workspace is never stamped" "true" "$(jq "$(ageOf "$box" w1) > 3600" -n)"
assertEq "the workspace that kept focus is stamped" "true" "$(jq "$(ageOf "$box" w3) < 5" -n)"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_DWELL_SECONDS=1 SESSION_PRUNER_LABELS=0 STUB_SERVER=running
  STUB_WORKSPACES="$(focusedOn w3)" run "$box" focus w1
)
sleep 2
assertEq "focus that moved on without an event is not stamped" "true" "$(jq "$(ageOf "$box" w1) > 3600" -n)"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_DWELL_SECONDS=0 SESSION_PRUNER_LABELS=0 STUB_SERVER=running
  STUB_WORKSPACES="$(focusedOn w1)" run "$box" focus w1
)
assertEq "dwell 0 stamps immediately" "true" "$(jq "$(ageOf "$box" w1) < 5" -n)"
rm -rf "$box"

# --------------------------------------------------------------------------
# Labels, pins, config
# --------------------------------------------------------------------------

echo "labels and pins"

box="$(newBox)"
makeStub "$box"
(
  export SESSION_PRUNER_TTL_HOURS=24 STUB_SERVER=running
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" refresh 2>/dev/null
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" refresh 2>/dev/null
)
assertEq "labels are pushed once per workspace" "w1 last_used=4d,w2 last_used=2d,w3 last_used=2d,w5 last_used=now" \
  "$(tr '\n' ',' <"$box/metadata" | sed 's/,$//')"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
(
  export STUB_SERVER=running HERDR_WORKSPACE_ID=w1
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" toggle-pin 2>/dev/null
)
assertEq "toggle-pin records the pin" "w1" "$(jq -r '. | join(",")' "$box/state/pins.json")"
assertEq "a pinned workspace shows the pin token" "w1 last_used=pin" \
  "$(head -1 "$box/metadata")"
(
  export STUB_SERVER=running HERDR_WORKSPACE_ID=w1
  STUB_WORKSPACES="$(liveWorkspaces)" run "$box" toggle-pin 2>/dev/null
)
assertEq "toggle-pin is a toggle" "" "$(jq -r '. | join(",")' "$box/state/pins.json")"
rm -rf "$box"

box="$(newBox)"
makeStub "$box"
mkdir -p "$box/config"
cat >"$box/config/config.env" <<'CFG'
# comment line
SESSION_PRUNER_TTL_HOURS=6
SESSION_PRUNER_PROTECT="^ops$"
NOT_MINE=ignored
CFG
assertEq "config.env is read" "SESSION_PRUNER_TTL_HOURS=6" \
  "$(run "$box" config | grep TTL_HOURS)"
assertEq "quoted values are unwrapped" 'SESSION_PRUNER_PROTECT=^ops$' \
  "$(run "$box" config | grep PROTECT=)"
assertEq "the environment beats config.env" "SESSION_PRUNER_TTL_HOURS=99" \
  "$(SESSION_PRUNER_TTL_HOURS=99 run "$box" config | grep TTL_HOURS)"
rm -rf "$box"

echo
if [ "$failures" -eq 0 ]; then
  echo "all tests passed"
else
  echo "$failures test(s) failed"
  exit 1
fi
