#!/usr/bin/env bash
# Cross-vendor judge for a fleet mission gate. The commander is Claude, so the judge is Codex (GPT):
# a different model family checks the claim of completion, read-only. Exit 0 only on "VERDICT: PASS".
# Usage: mission-judge.sh <mission dir>
set -u
M="${1:?mission dir}"; ROOT="$(dirname "$M")"
command -v codex >/dev/null || { echo "judge: codex CLI not found"; exit 1; }
LOG="$M/judge.log"
prompt="You are an independent auditor. A different AI (the commander of an agent fleet) claims the mission below is complete. Your job is to try to prove it is NOT.
Read, in this directory tree: mission/CONTRACT.md (the frozen contract), mission/out/REPORT.md (the commander's report), every file under mission/out/, and the last 200 lines of ledger.md.
For EACH line under 'Done means': find the concrete evidence (a file, a number, command output, a source URL quoted in the files). Open the files; run read-only commands if useful. A claim with no evidence in the files fails. Worker 'done' messages and confident wording are not evidence.
Also flag: invented numbers, sources that are cited but not used, report claims that contradict the files, and anything the contract marked out of scope.
Decide on the done-lines only. A done-line fails when its evidence is missing or the evidence contradicts it. Problems that do not affect whether a done-line is met (an unsupported side remark, style) are NOTES, not failures.
Output a short table: done-line | evidence found | ok/fail, then any notes. Then the final line: 'VERDICT: PASS' if every done-line is met with evidence, otherwise 'VERDICT: FAIL' followed by the single most important gap."
out="$(cd "$ROOT" && codex exec -s read-only --skip-git-repo-check "$prompt" < /dev/null 2>&1)"
printf '\n===== %s\n%s\n' "$(date '+%F %T')" "$out" >> "$LOG"
verdict="$(printf '%s\n' "$out" | grep -E '^\**VERDICT:\** *(PASS|FAIL)' | tail -1)"
printf '%s\n' "$out" | grep -vE '^(hook:|tokens used|[0-9,]+$)' | tail -25
printf '%s' "$verdict" | grep -qE '^\**VERDICT:\** *PASS([^A-Za-z]|$)' && exit 0
echo "judge verdict: ${verdict:-none}"; exit 1
