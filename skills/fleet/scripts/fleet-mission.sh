# fleet-mission.sh — give the commander a self-driving, verified mission loop.
# Sourced by fleet-herdr-lib.sh. Needs FLEET_ROOT (and the lib's fleet_pane / fleet_status / fleet_ledger_add).
#
# The loop (all native Prime Agent features, verified live on 2026-11-25):
#   /goal --budget N <objective>   the commander re-prompts itself every turn until it calls goal.complete()
#   /autonomous on --gate <check>  when it claims completion, the gate runs; a failing gate sends it back to work
# What this file adds on top:
#   - a CONTRACT written and approved BEFORE the run (objective, done-means, limits)
#   - a gate the commander cannot quietly change: contract + gate are hash-pinned at arm time;
#     any edit afterwards makes the gate fail closed
#   - a cross-vendor judge (Codex) inside the gate, so the Claude commander never grades itself
#   - a watchdog outside the commander that detects "busy but no progress" from real file changes
#   - one OUTCOME per mission: verified-success | budget-exhausted | blocked | cancelled
#
#   fleet_mission_new "<objective>"        scaffold mission/CONTRACT.md + mission/gate.sh
#   fleet_mission_arm [token_budget] [hours]  pin hashes, start watchdog, arm /autonomous + /goal on cmd
#   fleet_mission_status                   contract, gate log, outcome, watchdog, global-harness drift
#   fleet_mission_stop <outcome> "<why>"   end it (blocked | cancelled | budget-exhausted)

_fm_dir()  { printf '%s/mission' "$FLEET_ROOT"; }
_FM_JUDGE="$HOME/.claude/skills/fleet/scripts/mission-judge.sh"
_fm_hash() { cat "$(_fm_dir)/CONTRACT.md" "$(_fm_dir)/gate.sh" "$_FM_JUDGE" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }
_fm_harness_hash() { cat "$HOME/.prime/agent/harness/harness_state.json" 2>/dev/null | shasum -a 256 | cut -d' ' -f1; }

# Switch the commander's loop fully off once it is idle (used on success, stop, and before a new mission).
_fm_disarm() {
  local pane; pane="$(fleet_pane cmd)"; [ -n "$pane" ] || return 0
  (
    i=0; while [ "$(fleet_status cmd)" = "working" ] && [ $i -lt 300 ]; do sleep 2; i=$((i+1)); done
    for c in "$@" "/autonomous off"; do fleet_paste "$pane" "$c"; sleep 0.8; herdr pane send-keys "$pane" Enter >/dev/null 2>&1; sleep 2; done
  ) >/dev/null 2>&1 &
}

fleet_mission_new() {
  local obj="$*" d; d="$(_fm_dir)"
  [ -n "$obj" ] || { echo "usage: fleet_mission_new \"<objective>\"" >&2; return 1; }
  if [ -f "$d/.armed" ] && [ ! -f "$d/OUTCOME" ]; then echo "a mission is still armed; fleet_mission_stop it first" >&2; return 1; fi
  if [ -d "$d" ]; then mv "$d" "$FLEET_ROOT/mission-$(date +%Y%m%d-%H%M%S)"; _fm_disarm; fi
  mkdir -p "$d/out"
  cat > "$d/CONTRACT.md" <<EOF
# Mission contract  (frozen once armed: any edit makes the gate fail)

## Objective
$obj

## Done means  (every line must be checkable by a command or by opening a file)
- [ ] <measurable result 1: a file, a number, a passing command>
- [ ] <measurable result 2>
- [ ] Final report at mission/out/REPORT.md: what was done, evidence for each done-line, what was re-checked before finishing, known limits, and what is still uncertain.

## Evidence that counts
Files under mission/out/ and the fleet ledger, each claim with a source (URL, file path, or command output).
Worker "done" messages and the commander's own confidence do not count.

## Out of scope
- <what not to do>

## Limits
- Token budget (commander): set at arm time
- Wall clock: set at arm time
- Paid fallbacks: none. If a provider quota runs out, stop as budget-exhausted.
EOF
  cat > "$d/gate.sh" <<'EOF'
#!/usr/bin/env bash
# Mission gate. Runs when the commander claims the goal is complete. Exit 0 = verified success.
# Put the deterministic checks for every "Done means" line here, then the cross-vendor judge.
set -u
M="$(cd "$(dirname "$0")" && pwd)"
fail() { echo "GATE FAIL: $*"; exit 1; }

[ -s "$M/out/REPORT.md" ] || fail "mission/out/REPORT.md missing or empty"
# --- deterministic checks (edit before arming) ---
# example: [ "$(wc -l < "$M/out/primes.txt")" -eq 20 ] || fail "primes.txt needs 20 lines"

# --- independent judge: a different model family reads the contract + report + evidence ---
"${MISSION_JUDGE:-$HOME/.claude/skills/fleet/scripts/mission-judge.sh}" "$M" || fail "judge did not pass"
echo "GATE PASS"
EOF
  chmod +x "$d/gate.sh"
  echo "scaffolded $d/CONTRACT.md and $d/gate.sh: fill in 'Done means' + deterministic checks, show the user, then fleet_mission_arm"
}

fleet_mission_arm() {
  local budget="${1:-1500000}" hours="${2:-4}" d pane gate obj
  d="$(_fm_dir)"; pane="$(fleet_pane cmd)"
  [ -f "$d/CONTRACT.md" ] && [ -x "$d/gate.sh" ] || { echo "no mission scaffolded (fleet_mission_new)" >&2; return 1; }
  grep -q '<measurable result' "$d/CONTRACT.md" && { echo "CONTRACT.md still has template placeholders" >&2; return 1; }
  case "$budget$hours" in *[!0-9]*) echo "budget and hours must be integers" >&2; return 1;; esac
  rm -f "$d/OUTCOME"
  _fm_hash > "$FLEET_ROOT/.mission.pin"          # pins live OUTSIDE mission/ so editing mission files can't move them
  _fm_harness_hash > "$FLEET_ROOT/.harness.pin"
  date +%s > "$d/.armed"
  gate="$FLEET_ROOT/mission-gate-run.sh"
  cat > "$gate" <<EOF
#!/usr/bin/env bash
# Generated by fleet_mission_arm. The commander's autonomous gate. Fails closed if the contract or gate changed.
cd "$FLEET_ROOT" || exit 1
now="\$(cat "$d/CONTRACT.md" "$d/gate.sh" "$_FM_JUDGE" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)"
if [ "\$now" != "\$(cat "$FLEET_ROOT/.mission.pin")" ]; then
  echo "GATE FAIL: CONTRACT.md, gate.sh or the judge changed after arming. Restore them; the contract is frozen."
  echo "\$(date '+%F %T') FAIL tampered" >> "$d/gate.log"; exit 1
fi
export MISSION_JUDGE="$_FM_JUDGE"   # the real judge, always: no env override can skip it
out="\$("$d/gate.sh" 2>&1)"; rc=\$?
printf '%s rc=%s\n%s\n' "\$(date '+%F %T')" "\$rc" "\$out" >> "$d/gate.log"
echo "\$out"
if [ \$rc -eq 0 ]; then
  echo "verified-success" > "$d/OUTCOME"; touch "$d/.done"
  FLEET_ROOT="$FLEET_ROOT" bash -c '. "$HOME/.claude/skills/fleet/scripts/fleet-herdr-lib.sh"; fleet_ledger_add mission OUTCOME "verified-success"; _fm_disarm' >/dev/null 2>&1 &
fi
exit \$rc
EOF
  chmod +x "$gate"
  obj="$(awk '/^## Objective/{f=1;next} /^## /{f=0} f&&NF' "$d/CONTRACT.md" | tr '\n' ' ')"
  _fm_watchdog_start
  # Arm after the commander's current turn ends (it may be the one calling this).
  (
    i=0; while [ "$(fleet_status cmd)" = "working" ] && [ $i -lt 600 ]; do sleep 2; i=$((i+1)); done
    fleet_paste "$pane" "/autonomous on --gate $gate --max-continuations 25 --max-turns unlimited --max-tokens unlimited --timeout-ms $((hours*3600000)) --gate-timeout-ms 900000"
    sleep 0.8; herdr pane send-keys "$pane" Enter >/dev/null 2>&1; sleep 3
    fleet_paste "$pane" "/goal --budget $budget MISSION: $obj -- Contract: $d/CONTRACT.md (frozen; do not edit it or gate.sh). Follow ~/.claude/skills/fleet/MISSION.md. Call goal.complete() only when every Done-means line is met with evidence in $d/out; the gate and an independent judge will check."
    sleep 0.8; herdr pane send-keys "$pane" Enter >/dev/null 2>&1
  ) >/dev/null 2>&1 &
  command -v fleet_ledger_add >/dev/null && fleet_ledger_add user MISSION "armed: $obj (budget ${budget} tok, ${hours}h) -> mission/CONTRACT.md"
  echo "armed: budget ${budget} tokens, ${hours}h wall clock, gate $gate. Commander starts when its current turn ends."
}

# Watchdog: real progress = new ledger lines or new/changed files in outbox/ or mission/out/.
# 15 quiet minutes -> nudge the commander to re-plan. 3 nudges with still no progress -> stop as blocked.
_fm_progress_sig() { { grep -vE '^(watchdog|mission)'$'\t' "$FLEET_ROOT/ledger.md" 2>/dev/null | wc -c; find "$FLEET_ROOT/outbox" "$(_fm_dir)/out" -type f -exec stat -f '%m %z %N' {} + 2>/dev/null | sort; } | shasum | cut -d' ' -f1; }
_fm_watchdog_start() {
  local pidf="$FLEET_ROOT/.mission-watchdog.pid"
  [ -f "$pidf" ] && kill "$(cat "$pidf")" 2>/dev/null
  (
    last="$(_fm_progress_sig)"; quiet=0; nudges=0
    while [ ! -f "$(_fm_dir)/OUTCOME" ]; do
      sleep "${MISSION_WATCHDOG_S:-300}"
      now="$(_fm_progress_sig)"
      if [ "$now" != "$last" ]; then last="$now"; quiet=0; nudges=0; continue; fi
      quiet=$((quiet+1))
      if [ $quiet -ge 3 ]; then
        quiet=0; nudges=$((nudges+1))
        if [ $nudges -ge 3 ]; then fleet_mission_stop blocked "watchdog: no progress for 45+ minutes"; break; fi
        fleet_task cmd "WATCHDOG ($nudges/3): no new ledger lines or output files in 15 minutes. You are busy but not progressing. Re-plan: name the single biggest gap to the contract, change approach, delegate it, and post a ledger line. After 3 warnings the mission stops as blocked."
        fleet_ledger_add watchdog STALL "nudge $nudges/3"
      fi
    done
  ) >/dev/null 2>&1 &
  echo $! > "$pidf"
}

fleet_mission_stop() {
  local outcome="${1:-cancelled}" why="${2:-}" d pane; d="$(_fm_dir)"; pane="$(fleet_pane cmd)"
  case "$outcome" in blocked|cancelled|budget-exhausted) ;; *) echo "outcome must be blocked|cancelled|budget-exhausted" >&2; return 1;; esac
  printf '%s\n%s\n' "$outcome" "$why" > "$d/OUTCOME"
  [ -f "$FLEET_ROOT/.mission-watchdog.pid" ] && kill "$(cat "$FLEET_ROOT/.mission-watchdog.pid")" 2>/dev/null
  _fm_disarm "/goal clear"
  command -v fleet_ledger_add >/dev/null && fleet_ledger_add mission OUTCOME "$outcome: $why"
  echo "mission stopped: $outcome"
}

fleet_mission_status() {
  local d; d="$(_fm_dir)"
  [ -f "$d/CONTRACT.md" ] || { echo "no mission"; return; }
  echo "objective: $(awk '/^## Objective/{f=1;next} /^## /{f=0} f&&NF' "$d/CONTRACT.md" | head -2 | tr '\n' ' ')"
  if [ -f "$d/.armed" ]; then echo "armed:     $(date -r "$(cat "$d/.armed")" '+%F %T')"; else echo "armed:     no"; fi
  if [ -f "$FLEET_ROOT/.mission.pin" ]; then
    [ "$(_fm_hash)" = "$(cat "$FLEET_ROOT/.mission.pin")" ] && echo "contract:  intact" || echo "contract:  CHANGED SINCE ARMING (gate will fail; or this mission was armed before the judge was pinned)"
  fi
  echo "outcome:   $(head -1 "$d/OUTCOME" 2>/dev/null || echo running)"
  [ -f "$d/gate.log" ] && echo "last gate: $(grep -E '^[0-9]{4}-' "$d/gate.log" | tail -1)"
  local wp="$FLEET_ROOT/.mission-watchdog.pid"
  [ -f "$wp" ] && kill -0 "$(cat "$wp")" 2>/dev/null && echo "watchdog:  running" || echo "watchdog:  off"
  if [ -f "$FLEET_ROOT/.harness.pin" ] && [ "$(_fm_harness_hash)" != "$(cat "$FLEET_ROOT/.harness.pin")" ]; then
    echo "WARNING:   the GLOBAL Prime Agent harness changed during this mission (affects every agent in every fleet). Review ~/.prime/agent/harness/refinements.jsonl"
  fi
}
