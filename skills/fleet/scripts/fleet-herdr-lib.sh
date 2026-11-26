#!/usr/bin/env bash
# fleet-herdr-lib.sh — drive an ALL-PRIME-AGENT fleet on herdr.
# Prime Agent ships a built-in herdr reporter (herdr-agent-state extension): when PA runs
# inside a herdr pane it SELF-REPORTS working/idle/blocked/done over herdr's socket. So
# state is NATIVE (from the agent itself — no false-DONE), while input goes pane-level
# (bracketed paste + Enter, see fleet_paste). Agent names resolve to pane ids via $FLEET_ROOT/panes.map,
# written by the launcher (format: "<name>\t<pane_id>" per line).
#
#   source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh

: "${FLEET_ROOT:=$HOME/.fleets/hfleet}"
# each fleet is its OWN herdr session — target its socket for every herdr call
[ -f "$FLEET_ROOT/socket" ] && export HERDR_SOCKET_PATH="$(cat "$FLEET_ROOT/socket")"

# Type text into a pane as a bracketed PASTE, not keystrokes. Prime Agent's TUI drops a repeated
# keystroke ("aabb" arrives as "ab", "coffee" as "cofe"); a paste arrives intact, multi-line too.
fleet_paste() { herdr pane send-text "$1" "$(printf '\033[200~%s\033[201~' "$2")" >/dev/null 2>&1; }

fleet_names() { awk -F'\t' '{print $1}' "$FLEET_ROOT/panes.map" 2>/dev/null; }
fleet_pane()  { awk -F'\t' -v n="$1" '$1==n{print $2}' "$FLEET_ROOT/panes.map" 2>/dev/null; }

# native state, self-reported by Prime Agent: idle|working|blocked|done|unknown
fleet_status() {
  local pane; pane="$(fleet_pane "$1")"; [ -n "$pane" ] || { echo unknown; return; }
  herdr pane list 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unknown'); sys.exit()
for p in d.get('result',{}).get('panes',[]):
    if p.get('pane_id')=='$pane':
        print(p.get('agent_status') or 'unknown'); break
else: print('unknown')" 2>/dev/null
}

fleet_board() {
  local n
  while read -r n; do
    printf '%-8s %s\n' "$n" "$(fleet_status "$n")"
  done < <(fleet_names)
}

# Dispatch: type the task into the agent's pane, then Enter (separately — avoids the
# Enter-race on TUIs). State readback is native so completion is trustworthy.
#   fleet_task cc-1 "the slice"          -> submit, return immediately
#   WAIT=1 fleet_task cc-1 "the slice"   -> submit, block until done/idle
#   CONTRA=1 appends the cross-model check note.
fleet_task() {
  local n="$1"; shift
  local text="$*" pane; pane="$(fleet_pane "$n")"
  [ -n "$pane" ] || { echo "unknown agent: $n" >&2; return 1; }
  [ "${CONTRA:-0}" = "1" ] && text="$text
CONTRARIAN pass required: before finalizing, run your cross-model check (cc->codex, cx->claude), verify externally, then post to the ledger."
  date +%s > "$FLEET_ROOT/.task-$n" 2>/dev/null
  fleet_paste "$pane" "$text"
  sleep 0.8
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1
  [ "${WAIT:-0}" = "1" ] && fleet_wait "$n" "${TIMEOUT_S:-1800}"
  return 0
}

# Finished = self-reported done/idle/blocked, OR its outbox was written after the last dispatch and
# ends with an ANCHOR line (self-reported pane state can go stale; the evidence file is the truth).
fleet_finished() {
  local n="$1" s ob t0; s="$(fleet_status "$n")"
  case "$s" in done|idle|blocked) echo "$s"; return 0;; esac
  ob="$FLEET_ROOT/outbox/$n.md"; t0="$(cat "$FLEET_ROOT/.task-$n" 2>/dev/null || echo 0)"
  if [ -f "$ob" ] && [ "$(stat -f %m "$ob" 2>/dev/null || echo 0)" -ge "$t0" ] && fleet_has_anchor "$n"; then echo "done(anchor)"; return 0; fi
  return 1
}

# Block until one agent reaches done/idle (poll of its self-reported state).
fleet_wait() {
  local n="$1" timeout="${2:-1800}" waited=0 s
  while :; do
    s="$(fleet_finished "$n")" && { echo "$n: $s"; return 0; }
    [ "$waited" -ge "$timeout" ] && { echo "$n: timeout (still $(fleet_status "$n"))"; return 1; }
    sleep 3; waited=$((waited+3))
  done
}

# Wait until ANY worker (not cmd) is done/idle/blocked; echo the finisher(s).
fleet_wait_any() {
  local timeout="${1:-600}" waited=0 n s finished
  while :; do
    finished=""
    while read -r n; do
      [ "$n" = "cmd" ] && continue
      fleet_finished "$n" >/dev/null && finished="$finished $n"
    done < <(fleet_names)
    [ -n "$finished" ] && { echo "${finished# }"; return 0; }
    [ "$waited" -ge "$timeout" ] && { echo "(none finished within ${timeout}s)"; return 1; }
    sleep 3; waited=$((waited+3))
  done
}

# True when no worker is working -> the fleet has drained.
fleet_idle() {
  local n
  while read -r n; do
    [ "$n" = "cmd" ] && continue
    [ "$(fleet_status "$n")" = "working" ] && return 1
  done < <(fleet_names)
  return 0
}

fleet_capture() { local p; p="$(fleet_pane "$1")"; [ -n "$p" ] && herdr pane read "$p" --lines "${2:-40}" 2>/dev/null; }
fleet_focus()   { local p; p="$(fleet_pane "$1")"; [ -n "$p" ] && herdr pane focus --pane "$p" >/dev/null 2>&1; }

# --- shared ledger / evidence anchor: same file-based methodology as always ---
fleet_ledger_add() { local who="$1" type="$2"; shift 2; printf '%s\t%s\t%s\n' "$who" "$type" "$*" >> "$FLEET_ROOT/ledger.md"; }
fleet_ledger()     { cat "$FLEET_ROOT/ledger.md" 2>/dev/null; }
fleet_has_anchor() { grep -qiE '^ANCHOR:' "$FLEET_ROOT/outbox/$1.md" 2>/dev/null; }

# mission loop (goal + gate + judge + watchdog)
. "$(dirname "${BASH_SOURCE[0]:-$0}")/fleet-mission.sh"
