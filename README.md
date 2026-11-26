# prime-fleet

**Model-agnostic, goal-driven, cross-verified AI agent fleet.**

Eight agents, any models you want. Give the lead one a goal and it keeps working until a model from another company checks the work and agrees.

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/robellephrm/prime-fleet/main/install.sh | bash
```

After installing:

1. Open a new terminal.
2. Run `prime-agent`, then `/login` once for Anthropic, OpenAI Codex, and OpenRouter.
3. Start a fleet with `fleet <name> <project-dir>`.

Use `herdr fleet <name>` to reopen a fleet and `fleets` to list fleets.

Alternatively, clone the repository and run the installer:

```bash
git clone https://github.com/robellephrm/prime-fleet.git
cd prime-fleet
./install.sh
```

## Requirements

Tested on macOS. Install these before running the installer:

- `herdr`: `brew install herdr`
- `prime-agent`: `curl -fsSL https://app.primeintellect.ai/prime-agent/install.sh | sh`
- `codex`: `npm i -g @openai/codex`
- `python3`: `brew install python`
- `git`: `brew install git`

## What it is

Each fleet has one commander and seven workers. Every agent runs a Prime Agent session in its own herdr pane.

Default models, picked fresh every time a fleet starts:

- One commander and three workers use the newest Claude Opus.
- Three workers use the newest GPT Sol, through Codex sign-in.
- One worker uses OpenRouter's free router, `openrouter/openrouter/free`, which always points at a free model.

The launcher reads Prime Agent's model list and takes the newest release of each tier, so a new Opus or Sol is used on the next launch with no changes. It skips the top tiers (Claude Fable, GPT Astra) because they cost several times the tokens. To pin a model or choose a different tier for one launch:

```bash
PA_CC_MODEL=claude-opus-5-5 PA_CX_MODEL=gpt-6-astra fleet <name> <project-dir>
```

`PA_CMD_MODEL` sets the commander, `PA_CC_MODEL` the Claude workers, `PA_CX_MODEL` the Codex workers, `PA_ST_MODEL` the free lane.

Agents share briefs, outboxes, an append-only ledger, and evidence marked with `ANCHOR:` lines. Each fleet keeps its state under `~/.fleets/<name>`.

## Missions

Every substantial job is a mission. Quick questions and status checks do not need one.

### How a mission works

1. You give the commander a goal.
2. The commander asks 2-4 questions to clarify the result and limits.
3. It writes a contract with checkable done-lines and a gate that tests them.
4. You approve the contract and limits.
5. Prime Agent's `/goal` and `/autonomous` run the mission on their own.
6. A hash-locked gate and an independent Codex judge decide whether it is done. Failed checks send the commander back to work.
7. A watchdog stops the mission if it stalls for 45 minutes without recorded progress.

The contract, gate, and judge are hash-pinned when armed. Later edits make the gate fail closed. The judge uses a different model family from the commander and tries to disprove completion.

Each mission ends as `verified-success`, `blocked`, `budget-exhausted`, or `cancelled`.

See the [mission playbook](skills/fleet/MISSION.md).

## Principles

Three rules apply to every agent:

1. Re-check earlier work before trusting it.
2. Fix causes and leave work that holds up on later runs.
3. Serve your intended goal. Ask when it is unclear.

See [PRINCIPLES.md](skills/fleet/PRINCIPLES.md).

## Costs and safety

Claude through Prime Agent uses your Claude plan. Prime Agent warns that subscription use may violate provider terms. An API key avoids that subscription-use concern.

Codex uses your ChatGPT plan. The OpenRouter free lane has no model charge.

Missions have a commander token budget and a time cap. Provider quota exhaustion stops the mission. Agents must not switch to paid models to continue past a limit.

## Known limits

Pane state is self-reported and can become stale. A fresh outbox containing an `ANCHOR:` line also counts as completion evidence.

Pane input uses bracketed paste because typed keystrokes can lose repeated letters.

The independent judge can miss errors.

## Repository layout

```text
install.sh
skills/
└── fleet/
    ├── MISSION.md
    ├── PRINCIPLES.md
    └── scripts/
        ├── launch-fleet-herdr.sh
        ├── fleet-herdr-lib.sh
        ├── fleet-mission.sh
        └── mission-judge.sh
```

## License

MIT.
