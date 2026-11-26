#!/usr/bin/env bash
# launch-fleet-herdr.sh — stand up the ALL-PRIME-AGENT fleet on HERDR.
# Every agent is Prime Agent; the MODEL is the variable (heterogeneous by design):
#   cmd        = Prime Agent @ newest Claude Opus        <- coordinator, left ~30%
#   cc-1..cc-3 = Prime Agent @ newest Claude Opus        <- QUANTITATIVE (grid left col)
#   cx-1..cx-3 = Prime Agent @ newest GPT "Sol" (Codex)  <- QUALITATIVE (grid right col)
#   st-1       = Prime Agent @ OpenRouter free router    <- free lane, under cmd (FLEET_STEALTH=1)
# Models resolve to the newest release of each tier at launch (see "models" below). Pin any
# lane with e.g. PA_CC_MODEL=claude-opus-5-5 fleet <name>.
#
# HOW IT DRIVES (verified live): Prime Agent's built-in herdr reporter self-reports
# working/idle/blocked/done over herdr's socket whenever PA runs inside a herdr pane
# (HERDR_ENV=1 + HERDR_SOCKET_PATH + HERDR_PANE_ID, which herdr sets in its panes).
# So we do NOT use `herdr agent start` (no prime-agent kind yet) — we `pane run` PA,
# wait for its self-reported idle, then drive with bracketed-paste send-text + send-keys.
#
# MULTI-FLEET: one fleet PER PROJECT, each in its own herdr space. FLEET_ROOT defaults to
# ~/.fleets/<project-dir-name>, so different projects never share state and can run at once.
#   FLEET_CWD=~/proj ./launch-fleet-herdr.sh
set -uo pipefail

FLEET_CWD="${FLEET_CWD:-$PWD}"
_slug=$(basename "$FLEET_CWD" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//'); _slug="${_slug:-fleet}"
FLEET_ROOT="${FLEET_ROOT:-$HOME/.fleets/$_slug}"
FLEET_STEALTH="${FLEET_STEALTH:-1}"     # 1 = add the st-1 OpenRouter stealth agent
PA_BOOT_S="${PA_BOOT_S:-120}"           # per-agent wait for PA's self-reported idle
CMD_RATIO="${CMD_RATIO:-0.40}"          # commander's share of the width

# --- models ---------------------------------------------------------------------
# Default "latest": each lane takes the newest release of a fixed TIER, read from Prime Agent's
# model catalog (live cache first, then the list bundled with Prime Agent):
#   Claude lanes -> newest claude-opus-*   (not Fable: top tier, several times the tokens)
#   Codex lanes  -> newest gpt-*-sol       (not Astra: top tier, several times the tokens)
# A new Opus or Sol release is picked up on the next launch with no edits. To pin a model or
# choose another tier, set the env var, e.g. PA_CC_MODEL=claude-opus-5-5 or PA_CX_MODEL=gpt-6-astra.
latest_model() {  # <provider> <python regex with version groups> <fallback>
  python3 - "$1" "$2" "$3" <<'PYEOF' 2>/dev/null || echo "$3"
import json, os, re, sys
prov, pat, fallback = sys.argv[1], re.compile(sys.argv[2]), sys.argv[3]
ids = set()
def walk(o):
    if isinstance(o, dict):
        if o.get('provider') == prov and isinstance(o.get('id'), str): ids.add(o['id'])
        for v in o.values(): walk(v)
    elif isinstance(o, list):
        for v in o: walk(v)
for f in ('~/.prime/agent/models/provider-model-catalog.v1.json', '~/.local/share/prime-agent/models.bundled.json'):
    try: walk(json.load(open(os.path.expanduser(f))))
    except Exception: pass
best = None
for i in ids:
    m = pat.fullmatch(i)
    if m:
        v = tuple(int(g or 0) for g in m.groups())
        if best is None or v > best[0]: best = (v, i)
print(best[1] if best else fallback)
PYEOF
}
resolve() { [ -z "$1" ] || [ "$1" = "latest" ] && latest_model "$2" "$3" "$4" || echo "$1"; }
OPUS_RE='claude-opus-(\d+)(?:-(\d+))?'          # claude-opus-5, claude-opus-5-5 (skips dated ids)
SOL_RE='gpt-(\d+)(?:\.(\d+))?-sol'               # gpt-6-sol, gpt-6.1-sol
PA_CMD_PROVIDER="${PA_CMD_PROVIDER:-anthropic}";  PA_CMD_MODEL="$(resolve "${PA_CMD_MODEL:-}" anthropic "$OPUS_RE" claude-opus-5-5)"
PA_CC_PROVIDER="${PA_CC_PROVIDER:-anthropic}";    PA_CC_MODEL="$(resolve "${PA_CC_MODEL:-}" anthropic "$OPUS_RE" claude-opus-5-5)"
PA_CX_PROVIDER="${PA_CX_PROVIDER:-openai-codex}"; PA_CX_MODEL="$(resolve "${PA_CX_MODEL:-}" openai-codex "$SOL_RE" gpt-6.1-sol)"
PA_ST_PROVIDER="${PA_ST_PROVIDER:-openrouter}";   PA_ST_MODEL="${PA_ST_MODEL:-openrouter/openrouter/free}"   # rotating free models; never needs updating
echo "models: cmd+cc=$PA_CMD_MODEL/$PA_CC_MODEL  cx=$PA_CX_MODEL  st=$PA_ST_MODEL"

command -v herdr >/dev/null 2>&1 || { echo "FATAL: herdr not on PATH" >&2; exit 1; }
command -v prime-agent >/dev/null 2>&1 || { echo "FATAL: prime-agent not on PATH (need ~/.local/bin)" >&2; exit 1; }


pj() { python3 -c "import sys,json;d=json.load(sys.stdin);print($1)" 2>/dev/null; }

# ONE HERDR SESSION PER FLEET (like tmux sessions): each fleet is an INDEPENDENT herdr
# server with its own socket/workspaces/panes ("use named sessions when you want
# independent Herdr servers"). Different terminals attach to different fleets and see
# different things. All herdr calls below target this fleet's session via its socket.
FLEET_NAME=$(basename "$FLEET_ROOT")
# sanitize herdr env inherited from a parent herdr pane — otherwise the new session server
# (and every agent in it) reports state to the PARENT session's socket and shows "unknown"
for _v in $(env | grep '^HERDR_' | cut -d= -f1); do unset "$_v"; done
export HERDR_SOCKET_PATH="$HOME/.config/herdr/sessions/$FLEET_NAME/herdr.sock"

# Pre-flight 1: relaunch = stop THIS fleet's previous session (other fleets untouched).
herdr session stop "$FLEET_NAME" >/dev/null 2>&1 || true
sleep 1
# Pre-flight 2: PER-FLEET daemon isolation. Each fleet runs its own PA daemon on its own
# socket ($FLEET_ROOT/pa.sock) so fleets never contend on one supervisor (the shared-daemon
# setup produced "Cannot list heartbeats while session worker is starting" spam under 2+
# fleets). Relaunch cleans only THIS fleet's daemon procs + socket/lock.
PA_SOCK="$FLEET_ROOT/pa.sock"
pkill -f -- "--daemon-socket $PA_SOCK" 2>/dev/null || true
sleep 1
rm -rf "$PA_SOCK" "$PA_SOCK.lock" 2>/dev/null || true
# also clear the legacy GLOBAL runtime dir, but only when no PA at all is running
if [ "$(pgrep -f prime-agent 2>/dev/null | wc -l | tr -d ' ')" = "0" ]; then
  rm -rf "${TMPDIR:-/tmp}/prime-agent-$(id -u)" 2>/dev/null || true
fi

# Pre-flight 3: start this fleet's OWN session server (headless) and wait for its socket.
echo "starting herdr session '$FLEET_NAME'..."
nohup herdr server --session "$FLEET_NAME" >/tmp/herdr-$FLEET_NAME.log 2>&1 &
_w=0; while [ ! -S "$HERDR_SOCKET_PATH" ] && [ "$_w" -lt 15 ]; do sleep 1; _w=$((_w+1)); done
[ -S "$HERDR_SOCKET_PATH" ] || { echo "FATAL: session '$FLEET_NAME' did not start (see /tmp/herdr-$FLEET_NAME.log)" >&2; exit 1; }
# purge workspaces restored from the previous run — session state persists across stop,
# so without this every relaunch stacks a duplicate fleet layout in the same session
for _w in $(herdr pane list 2>/dev/null | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print("\n".join(sorted(set(p["pane_id"].split(":")[0] for p in d.get("result",{}).get("panes",[])))))' 2>/dev/null); do
  herdr workspace close "$_w" >/dev/null 2>&1 || true
done

mkdir -p "$FLEET_ROOT/outbox" "$FLEET_ROOT/inbox" "$FLEET_ROOT/briefs"
: > "$FLEET_ROOT/ledger.md"
: > "$FLEET_ROOT/panes.map"

# --- roster (bash-3.2 portable: no associative arrays on stock macOS bash) ---
NAMES=(cc-1 cc-2 cc-3 cx-1 cx-2 cx-3)
[ "$FLEET_STEALTH" = "1" ] && NAMES=("${NAMES[@]}" st-1)
prov_of()  { case "$1" in cmd) echo "$PA_CMD_PROVIDER";; cc-*) echo "$PA_CC_PROVIDER";; cx-*) echo "$PA_CX_PROVIDER";; st-*) echo "$PA_ST_PROVIDER";; esac; }
model_of() { case "$1" in cmd) echo "$PA_CMD_MODEL";;    cc-*) echo "$PA_CC_MODEL";;    cx-*) echo "$PA_CX_MODEL";;    st-*) echo "$PA_ST_MODEL";; esac; }
role_of()  { case "$1" in cmd) echo commander;; cc-*) echo "Claude/QUANT";; cx-*) echo "Codex/QUAL";; st-*) echo "stealth/free";; esac; }

# --- briefs ------------------------------------------------------------------
cat > "$FLEET_ROOT/briefs/cmd.md" <<EOF
# You are the COMMANDER of a herdr fleet — Prime Agent @ $PA_CMD_MODEL. Every agent is Prime Agent;
# the MODEL differs. Workers: cc-1..cc-3 (Claude, QUANTITATIVE) + cx-1..cx-3 (Codex, QUALITATIVE)$([ "$FLEET_STEALTH" = "1" ] && echo " + st-1 (OpenRouter stealth = FREE lane)").
# You plan, delegate, synthesize — no heavy work yourself.
Root: $FLEET_ROOT · workdir: $FLEET_CWD.
First read ~/.claude/skills/fleet/PRINCIPLES.md: re-check before you trust, build for tomorrow, serve what the user wants.

Drive workers (state is self-reported to herdr and can go stale; fleet_wait/fleet_wait_any also count a fresh ANCHOR'd outbox as done):
  export FLEET_ROOT=$FLEET_ROOT; source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh && <fn>
  dispatch: fleet_task cc-1 "task"  (CONTRA=1 = cross-model check) · board: fleet_board
  wait-any: fleet_wait_any · read: fleet_capture cc-1 · ledger: fleet_ledger / fleet_ledger_add
Route quantitative/structured -> cc-*, qualitative/interpretive -> cx-*$([ "$FLEET_STEALTH" = "1" ] && echo ", cheap/exploratory/high-volume -> st-1 (it's free — use it to protect the metered engines)"). Form sparse 2-3 teams,
one owner each; pass POINTERS via the ledger, not transcripts. CONTRA=1 only on load-bearing outputs.
A deliverable isn't done until its outbox ends with a real ANCHOR (fleet_has_anchor).
Loop: fleet_wait_any -> read finisher -> give next task -> repeat; stop at a checkable done-test
or when idle with no valuable next task; reserve capacity for a final synthesis.

Every real job is a MISSION (default): follow ~/.claude/skills/fleet/MISSION.md. Ask the user 2-4 short questions to pin down what they want, propose the contract, arm it on their OK, then run self-directed until an independent gate + judge pass. Quick questions and status checks are not missions.
$(cat "$HOME/.claude/skills/fleet/cmd-extra.md" 2>/dev/null)
Right now: run fleet_board, tell the user you're ready, wait for the mission.
EOF
for i in 1 2 3; do
cat > "$FLEET_ROOT/briefs/cc-$i.md" <<EOF
# You are worker cc-$i — Prime Agent @ $PA_CC_MODEL (Claude, QUANTITATIVE), commanded by cmd.
Root: $FLEET_ROOT · cwd: $FLEET_CWD.
Read ~/.claude/skills/fleet/PRINCIPLES.md once; it governs every task (re-check before you trust, fix causes not symptoms, flag a task that misses the goal).
Per task: do it, then write a self-contained result to $FLEET_ROOT/outbox/cc-$i.md ENDING WITH an
evidence line "ANCHOR: <command output / resolved URL / passing test — not your say-so>". Your
state is auto-reported to herdr; the commander reads your outbox, not your screen. Post key
findings to the ledger (export FLEET_ROOT=$FLEET_ROOT; source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh && fleet_ledger_add cc-$i CLAIM "... -> outbox/cc-$i.md").
Contrarian ONLY when the task says CONTRARIAN — cross-model check via the OTHER engine:
codex exec -s read-only --skip-git-repo-check "<answer + strongest reason it's wrong>" < /dev/null.
Stay resource-lean (lightest tool first, no browser-per-subagent).
Right now: acknowledge you're cc-$i and wait for the commander.
EOF
cat > "$FLEET_ROOT/briefs/cx-$i.md" <<EOF
# You are worker cx-$i — Prime Agent @ $PA_CX_MODEL (Codex, QUALITATIVE), commanded by cmd.
Root: $FLEET_ROOT · cwd: $FLEET_CWD.
Read ~/.claude/skills/fleet/PRINCIPLES.md once; it governs every task (re-check before you trust, fix causes not symptoms, flag a task that misses the goal).
Per task: do it (use the shell), then write a self-contained result to $FLEET_ROOT/outbox/cx-$i.md
ENDING WITH "ANCHOR: <real proof>". Your state is auto-reported to herdr; the commander reads your
outbox. Post findings to the ledger (export FLEET_ROOT=$FLEET_ROOT; source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh && fleet_ledger_add cx-$i CLAIM "... -> outbox/cx-$i.md").
Contrarian ONLY when the task says CONTRARIAN — cross-model check via the OTHER engine:
claude -p "strongest reason this is wrong: <answer>" < /dev/null. Stay resource-lean.
Right now: acknowledge you're cx-$i and wait for the commander.
EOF
done
if [ "$FLEET_STEALTH" = "1" ]; then
cat > "$FLEET_ROOT/briefs/st-1.md" <<EOF
# You are worker st-1 — Prime Agent @ $PA_ST_MODEL (OpenRouter stealth), commanded by cmd.
Root: $FLEET_ROOT · cwd: $FLEET_CWD. Read ~/.claude/skills/fleet/PRINCIPLES.md once; it governs every task.
You are the FREE/exploratory lane — take cheap breadth-first,
speculative, or high-volume tasks so the metered engines stay reserved for load-bearing work.
Per task: do it, then write a self-contained result to $FLEET_ROOT/outbox/st-1.md ENDING WITH
"ANCHOR: <real proof>". Post findings to the ledger (export FLEET_ROOT=$FLEET_ROOT; source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh
&& fleet_ledger_add st-1 CLAIM "... -> outbox/st-1.md"). Stay resource-lean.
Right now: acknowledge you're st-1 and wait for the commander.
EOF
fi

# --- layout: cmd full-height left + THREE even worker columns (3 | 3 | 2) ---
#   [ cmd ][ cc-1 | cx-1 | st-1  ]
#   [     ][ cc-2 | cx-2 |_______]
#   [     ][ cc-3 | cx-3 | board ]
hsplit() { herdr pane split "$1" --direction "$2" --ratio "$3" --cwd "$FLEET_CWD" --no-focus 2>/dev/null | pj 'd["result"]["pane"]["pane_id"]'; }
echo "creating herdr workspace..."
ROOT=$(herdr workspace create 2>/dev/null | pj 'd["result"]["root_pane"]["pane_id"]')
[ -z "$ROOT" ] && { echo "FATAL: could not create workspace" >&2; exit 1; }
echo "${ROOT%%:*}" > "$FLEET_ROOT/workspace"
herdr workspace rename "${ROOT%%:*}" "$FLEET_NAME" >/dev/null 2>&1   # fleet name shows in the TUI top bar
echo "$HERDR_SOCKET_PATH" > "$FLEET_ROOT/socket"   # lib + board target this fleet's session
GRID=$(hsplit "$ROOT" right "$CMD_RATIO")
[ -z "$GRID" ] && { echo "FATAL: could not split grid region" >&2; exit 1; }
# three equal columns: cc | cx | st+board
COLA="$GRID"
COLB=$(hsplit "$COLA" right 0.3333)
COLC=$(hsplit "$COLB" right 0.5)
# column A: cc-1..3 stacked; column B: cx-1..3 stacked
R1="$COLA"; R2=$(hsplit "$R1" down 0.3333); R3=$(hsplit "$R2" down 0.5)
R1B="$COLB"; R2B=$(hsplit "$R1B" down 0.3333); R3B=$(hsplit "$R2B" down 0.5)
# column C: st-1 on top, board below (2 panes — the short column)
ST=""; BOARD="$COLC"
if [ "$FLEET_STEALTH" = "1" ]; then
  ST="$COLC"
  BOARD=$(hsplit "$COLC" down 0.55)   # st-1 keeps 55%, board below
fi
# name -> pane map lives in panes.map (bash-3.2 portable; the lib reads the same file)
printf '%s\t%s\n' cmd "$ROOT" cc-1 "$R1" cc-2 "$R2" cc-3 "$R3" cx-1 "$R1B" cx-2 "$R2B" cx-3 "$R3B" >> "$FLEET_ROOT/panes.map"
[ -n "$ST" ] && printf 'st-1\t%s\n' "$ST" >> "$FLEET_ROOT/panes.map"
pane_of() { awk -F'\t' -v n="$1" '$1==n{print $2}' "$FLEET_ROOT/panes.map"; }
# live status strip under cmd: alt-screen (NO scrollback), 2-col grid matching the fleet,
# fleet list + switcher hint bottom-right. Colors: green=working, dim=idle, cyan=done, red=blocked.
cat > "$FLEET_ROOT/board.sh" <<EOB
#!/usr/bin/env bash
export FLEET_ROOT="$FLEET_ROOT"
source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh
printf '\033[?25l'; trap 'printf "\033[?25h"' EXIT INT TERM; clear; printf '\033[3J'
col() { case "\$1" in working) printf '\033[1;32m';; idle) printf '\033[2;37m';; done) printf '\033[36m';; blocked) printf '\033[1;31m';; *) printf '\033[33m';; esac; }
cell() { local s; s=\$(fleet_status "\$1"); col "\$s"; printf '%-20s' "agent-\${1//-/} [\$s]"; printf '\033[0m'; }
while :; do
  W=\$(stty size 2>/dev/null </dev/tty | awk '{print \$2}'); [ -z "\$W" ] && W=60
  printf '\033[H'
  printf '\033[1m· %s fleet ·\033[0m\033[K\n' "$FLEET_NAME"
  for n in cmd cc-1 cc-2 cc-3 cx-1 cx-2 cx-3 st-1; do cell "\$n"; printf '\033[K\n'; done
  printf '\033[K\n'
  fl=""; for d in "\$HOME/.fleets"/*/; do [ -f "\$d/workspace" ] && fl="\$fl \$(basename "\$d")"; done
  tail_txt="fleets:\$fl"; tail_txt="\${tail_txt:0:\$((W-2))}"
  printf '\033[2m%s\033[0m\033[K\033[J' "\$tail_txt"
  sleep 5
done
EOB
[ -n "$BOARD" ] && herdr pane run "$BOARD" "bash $FLEET_ROOT/board.sh" >/dev/null 2>&1
echo "  cmd=$ROOT  grid: cc=$R1,$R2,$R3  cx=$R1B,$R2B,$R3B${ST:+  st=$ST}"

# --- boot Prime Agent in every pane, wait for self-reported idle, then brief ---
pane_status() { herdr pane list 2>/dev/null | python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print('unknown'); sys.exit()
for p in d.get('result',{}).get('panes',[]):
    if p.get('pane_id')=='$1': print(p.get('agent_status') or 'unknown'); break
else: print('unknown')" 2>/dev/null; }

start_agent() {  # <name>
  local n="$1" pane; pane="$(pane_of "$n")"
  herdr pane rename "$pane" "$n" >/dev/null 2>&1
  herdr pane run "$pane" "prime-agent --daemon-socket $PA_SOCK --provider $(prov_of "$n") --model $(model_of "$n")" >/dev/null 2>&1
}
brief_agent() {  # <name> — wait for PA's self-reported idle (one boot retry), then brief
  local n="$1" pane waited=0 s retried=0; pane="$(pane_of "$n")"
  while :; do
    s="$(pane_status "$pane")"
    [ "$s" = "idle" ] || [ "$s" = "done" ] && break
    if [ "$waited" -ge 45 ] && [ "$retried" = "0" ]; then
      echo "  $n not up at 45s — retrying its boot..."
      herdr pane send-keys "$pane" C-c >/dev/null 2>&1; sleep 1
      herdr pane run "$pane" "prime-agent --daemon-socket $PA_SOCK --provider $(prov_of "$n") --model $(model_of "$n")" >/dev/null 2>&1
      retried=1
    fi
    [ "$waited" -ge "$PA_BOOT_S" ] && { echo "  WARN: $n not idle after ${PA_BOOT_S}s (status: $s) — briefing anyway"; break; }
    sleep 3; waited=$((waited+3))
  done
  herdr pane send-text "$pane" "$(printf '\033[200~%s\033[201~' "Read $FLEET_ROOT/briefs/$n.md — that is your standing role. Adopt it and do exactly what its 'Right now' line says.")" >/dev/null 2>&1   # paste: typed keys lose doubled letters
  sleep 0.8
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1
}

ALL=(cmd "${NAMES[@]}")
sleep 3   # let fresh pane shells reach their prompt (slow rc files eat early input)
for n in "${ALL[@]}"; do
  echo "  launching $n (PA @ $(model_of "$n"), $(role_of "$n")) in $(pane_of "$n")..."
  start_agent "$n"
done
echo "waiting for self-reported readiness + briefing (PA boots take a while)..."
for n in "${ALL[@]}"; do
  brief_agent "$n"
  echo "  $n briefed ($(pane_status "$(pane_of "$n")"))"
done

echo
echo "fleet '$FLEET_NAME' up (own herdr session). Open it:  herdr fleet $FLEET_NAME"
echo "  board: export FLEET_ROOT=$FLEET_ROOT; source ~/.claude/skills/fleet/scripts/fleet-herdr-lib.sh && fleet_board"
