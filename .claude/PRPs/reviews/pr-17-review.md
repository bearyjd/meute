# PR Review: #17 — fix: discover records the repo's real default branch

**Reviewed**: 2026-09-06 · **Decision**: APPROVE

Found by using the tool at scale rather than by reading it. Two findings:
the semantic one (checked-out ≠ default) and the `set -e` one inside the
fix. The second is the third occurrence of the same bash shape in this
codebase, which is worth saying out loud: a failing `$(...)` in an
assignment aborts a function under `-e`, and it does so silently when the
output is captured. The mutation that drops the `|| true` fails three of
the four new assertions — exactly the ones with no `origin/HEAD` — so the
test discriminates the real failure from a wrong precedence order.

282/282. The 25-repo live manifest validated; all on main/master.
