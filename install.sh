#!/usr/bin/env bash
# prime-fleet installer: copies the fleet into ~/.claude/skills/fleet and adds the
# `fleet` / `fleets` shell commands. Safe to re-run.
# One-line install:  curl -fsSL https://raw.githubusercontent.com/robellephrm/prime-fleet/main/install.sh | bash
set -euo pipefail
REPO="https://github.com/robellephrm/prime-fleet.git"
SKILLS="$HOME/.claude/skills"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ ! -d "${SRC:-}/skills/fleet" ]; then
  # piped from curl: fetch the repo into a temp folder first
  command -v git >/dev/null 2>&1 || { echo "git is required"; exit 1; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  git clone --quiet --depth 1 "$REPO" "$TMP/prime-fleet"
  SRC="$TMP/prime-fleet"
fi

need() { command -v "$1" >/dev/null 2>&1 || MISSING="${MISSING:-}$1 "; }
need herdr; need prime-agent; need codex; need python3; need git
if [ -n "${MISSING:-}" ]; then
  echo "missing: $MISSING"
  echo "  herdr        brew install herdr"
  echo "  prime-agent  curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh"
  echo "  codex        npm i -g @openai/codex   (used as the independent mission judge)"
  echo "  python3/git from your package manager"
  echo "Install them, then re-run this script."; exit 1
fi

mkdir -p "$SKILLS/fleet/scripts"
cp "$SRC"/skills/fleet/*.md "$SKILLS/fleet/"
cp "$SRC"/skills/fleet/scripts/*.sh "$SKILLS/fleet/scripts/"
chmod +x "$SKILLS"/fleet/scripts/*.sh

case "${SHELL:-}" in *bash) RC="$HOME/.bashrc" ;; *) RC="$HOME/.zshrc" ;; esac
touch "$RC"
if grep -q '# ===== fleet command =====' "$RC"; then
  sed -i.bak '/# ===== fleet command =====/,/# ===== end fleet command =====/d' "$RC" && rm -f "$RC.bak"
fi
cat >> "$RC" <<'FLEET_RC_EOF'

# ===== fleet command =====
# fleet <name> [dir]   launch (or update) a fleet named <name> working in [dir], then open it
# herdr fleet <name>   reopen a running fleet        fleets   list fleets
fleet() {
  local dir="$PWD" name=""
  if [ -n "${1:-}" ]; then
    if [ -d "$1" ]; then dir="$1"
    else
      name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
      [ -n "${2:-}" ] && [ -d "$2" ] && dir="$2"
    fi
  fi
  [ -z "$name" ] && name=$(basename "$dir" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
  FLEET_ROOT="$HOME/.fleets/$name" FLEET_CWD="$dir" "$HOME/.claude/skills/fleet/scripts/launch-fleet-herdr.sh" || return 1
  if [ -n "${HERDR_ENV:-}" ] || [ -n "${HERDR_PANE_ID:-}" ]; then
    echo "fleet '$name' is up. You are inside herdr; open a new terminal and run: herdr fleet $name"
  else
    command herdr session attach "$name"
  fi
}
herdr() {
  if [ "${1:-}" = "fleet" ] && [ -n "${2:-}" ]; then
    local slug; slug=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-*//;s/-*$//')
    if [ -n "${HERDR_ENV:-}" ] || [ -n "${HERDR_PANE_ID:-}" ]; then echo "you are inside herdr; open a new terminal and run: herdr fleet $slug"
    elif [ -f "$HOME/.fleets/$slug/socket" ]; then command herdr session attach "$slug"
    else echo "no fleet named '$slug'. Start one: fleet $slug"; fi
  else command herdr "$@"; fi
}
fleets() { command herdr session list 2>/dev/null | awk 'NR>1 && $1!="default" {printf "  %-16s %-8s  herdr fleet %s\n", $1, $2, $1}'; }
# ===== end fleet command =====
FLEET_RC_EOF

echo "installed. Open a new terminal, then:"
echo "  1. sign in once inside Prime Agent:  prime-agent   then  /login  (Anthropic, OpenAI Codex, OpenRouter)"
echo "  2. start a fleet:                    fleet myfleet ~/path/to/project"
