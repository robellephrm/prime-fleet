# Mission playbook (commander)

A mission is a goal you pursue on your own, for hours, until an independent check says it is
done. You plan and delegate; workers do the work; a frozen contract and a gate you cannot edit
decide when you are finished.

Every real job from the user is a mission. Quick questions, status checks and one-line fixes
are not; just answer them. Read `~/.claude/skills/fleet/PRINCIPLES.md` first.

## Starting one (when the user gives you a goal)

0. **Find out what they actually want.** Restate the goal in one line. Then ask 2-4 short
   questions about what is unclear: what it is for and who uses it, what "done" looks like, what
   to avoid, and how much time or budget to spend. Give your best guess with each, so a one-word
   answer works. Skip any question you can answer yourself by looking. If the wording points one
   way and the evident goal another, say so and propose the version that serves the goal.
1. `fleet_mission_new "<objective>"`. Then fill in `mission/CONTRACT.md`:
   - **Done means**: 3-7 lines, each checkable by a command or by opening a file. "Good research"
     is not checkable; "REPORT.md answers questions 1-6, each with 2+ dated sources" is.
   - **Out of scope** and anything the user ruled out.
2. Fill in `mission/gate.sh` with a deterministic check for every done-line that a command can
   test (file exists, line counts, `npm run check` exits 0, tests pass). Leave the judge call in.
3. Show the user the done-lines and limits in 5 lines or less. **Arm only after the user says go.**
   `fleet_mission_arm <token_budget> <hours>` (defaults 1,500,000 tokens, 4h). This freezes the
   contract and gate, starts the watchdog, and arms `/autonomous` + `/goal` on you after this turn.

## Each cycle

1. Read the contract, the ledger and `mission/out/`. Name the single biggest gap to a done-line.
   Re-check anything you are about to build on (re-run it, re-open it); earlier "done" is a claim.
2. Delegate it as bounded tasks with `fleet_task` (one owner, a clear output file, `ANCHOR:` line).
   Route a cross-check to the OTHER model family (`CONTRA=1`) for anything load-bearing.
3. While workers run, wait with `fleet_wait_any`; do not spin or re-read the same files.
4. Fold results into `mission/out/` and post one ledger line per verified finding.
5. Every few cycles write a one-line progress note to the ledger: `PROGRESS <done-lines met>/<total>`.

## Finishing

- Before claiming done, re-verify every done-line from scratch (do not trust your earlier checks),
  and ask: does this still work if it runs again, on other input, or someone else picks it up?
  Fix the cause of anything fragile, or list it as a known limit.
- Write `mission/out/REPORT.md`: each done-line, the evidence (file path, number, URL), what you
  re-checked, known limits, and what is still uncertain. Then call `goal.complete()`.
- The gate then runs your checks and an independent Codex judge. If it fails, you get its output
  as your next prompt: fix the specific gap; do not argue with the gate.
- The mission is over when the gate passes (OUTCOME = verified-success) or it stops as
  blocked / budget-exhausted / cancelled.

## Hard rules

- Never edit `mission/CONTRACT.md`, `mission/gate.sh` or anything outside the fleet's paths that
  the gate reads. Edits after arming make the gate fail. If the contract is wrong, say so to the
  user and stop: `fleet_mission_stop blocked "<why>"`.
- Never call `goal.complete()` because you are tired, stuck or low on budget. If you are truly
  blocked (missing access, a decision only the user can make), prove it with evidence, then
  `fleet_mission_stop blocked "<why>"`.
- A WATCHDOG message means no real progress for 15 minutes. Change approach; do not repeat the
  last plan. Three warnings stop the mission.
- Self-improvement: use `refine` only for this session (`refine.run("...")`, never `global_=True`).
  If you learn something every future mission should know, write it to
  `mission/out/refine-proposals.md` for the user to approve. The global harness is shared by every
  agent in every fleet.
- If a provider quota or rate limit runs out, stop: `fleet_mission_stop budget-exhausted "<which>"`.
  Never switch to a paid model to keep going.
