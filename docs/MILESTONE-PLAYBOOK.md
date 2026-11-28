# Meute milestone delivery playbook

Run this playbook with a roadmap source and a target milestone or slice. Work through its dependencies in order, one pull request at a time. The run ends when those changes have landed and the target's acceptance checks pass on the integrated result.

The playbooks themselves live in [bearyjd/meute-paseo-playbooks](https://github.com/bearyjd/meute-paseo-playbooks). Clone it and link its `playbooks/` directory to `.paseo/plugins/playbooks` in this checkout.

## Start a run

In the Meute workspace, open Paseo Playbooks and choose **Deliver a Meute roadmap milestone**. Enter the target ID and roadmap scope or source. Enable **Merge authorized** to allow the run to push, open PRs, and merge each approved head after CI passes.

To run the same workflow from a Meute agent session, copy this prompt and fill in the target and scope.

```text
Run docs/MILESTONE-PLAYBOOK.md through <milestone or slice ID>.
Roadmap source: <path, link, or pasted scope and acceptance criteria>
Base branch: main
Authorization: create and push branches, open PRs, and merge the approved
head after CI is green for each in-scope slice.
Report each merged slice and its evidence. Continue until the target passes
its acceptance checks or a blocker prevents further in-scope progress.
```

Adjust the authorization to match the run. Record any acceptance checks that need a named environment or operator action. A rollout counts toward completion when the roadmap calls for it and the run has the access and authorization to verify it.

## Establish the milestone scope

1. Read the roadmap entry and trace its dependencies through the target. Compare each slice with the base branch and existing PRs. Record what has landed, what still needs a PR, and the acceptance evidence each slice requires.
2. Agree on the intended behavior from the roadmap and current callers. Resolve routine implementation choices during the run. Raise product decisions that materially change the acceptance criteria, particularly decisions about which operator surfaces can mutate state.
3. Start each new slice in an isolated worktree from the updated base branch. Keep a record of the slice ID, base SHA, acceptance criteria, tests, review verdict, PR, reviewed head SHA, and merge SHA. Use the PR description once opened so the next session can resume from it.

## Build and verify the slice

1. Implement the smallest complete slice through its normal entry points. Exercise existing behavior that callers rely on and add regression coverage where the acceptance criteria call for it. For stateful changes, test retry, concurrency, partial failure, and legacy state where applicable.
2. Run focused tests first, then the Meute CI suites below in the isolated worktree. Run any additional acceptance checks required by the slice, such as a real browser or container smoke test, and record the environment and result.

   ```bash
   bash tests/test_meute.sh
   python3 -m unittest discover tests
   ```

3. If a local test fails, reproduce it and fix regressions. If it also fails on the base, record both results and determine whether it undermines acceptance. A base failure still needs a green PR check before merge. If a shared CI failure needs its own fix, land that prerequisite through this same loop.

## Review, fix, and repeat

Commit the candidate and give an independent reviewer the base and head SHAs, acceptance criteria, changed entry points, and test evidence. Use a fresh, read-only review session with access to the committed diff. For container boundary or credential changes, follow the Codex adversarial review requirement in [the Meute handoff](HANDOFF.md#how-to-resume).

Use this review brief.

```text
Review the committed diff from <base SHA> to <head SHA> against the attached
acceptance criteria. Try to falsify the claims through normal entry points.
Check behavior regressions, stale inputs, interrupted operations, retries,
and concurrent callers where relevant. Run focused checks in an isolated
checkout if needed. Leave the implementation untouched.

For each finding, give the affected file and line, observable impact,
and the condition that triggers it. Report the reviewed SHA, checks run,
and a verdict of APPROVE or REQUEST CHANGES.
```

Investigate every finding. Fix confirmed defects and add a regression test where it can demonstrate the failure. Record evidence for findings that do not reproduce or do not apply. Move a genuine defect outside the slice only with a recorded owner decision. After any fix, rerun focused and applicable full tests, commit, and request review of the new head. Repeat until the current head has independent approval and every finding has a disposition.

## Merge on green CI

1. Open or update the PR with its slice ID, acceptance results, and review evidence. Wait for the Meute `test` workflow and all other required checks on the reviewed PR head. Treat absent, pending, cancelled, skipped, or failed required checks as unresolved. If CI fails, inspect the logs, fix the cause, and return to review for any new commit.
2. Immediately before merging, verify the current PR head matches the approved SHA, the checks have passed, and GitHub reports the PR can merge under branch protections. If a base update changes the candidate, rerun verification and review as needed for the new base and head. Use the repository's allowed merge method and pin the reviewed SHA. For a merge commit, GitHub CLI supports `gh pr merge <PR> --merge --match-head-commit <reviewed SHA>`. Follow the repository's merge queue if enabled and wait for the merge to finish.
3. Confirm the PR merged and the result reached the target branch. Record the merge SHA, then update the base for the next slice. When the target's PRs have landed, run the milestone's acceptance checks on the integrated result and report what passed and which acceptance checks remain open.

## Resume a run

Start from the current PR and GitHub state. Reuse test and review evidence tied to the same candidate. If a push or merge returned an uncertain result, check the remote state before retrying. Continue with independent in-scope slices when a dependency permits it. If progress stops, report the last verified SHA, the remaining acceptance criteria, and the specific decision, access, or failing check needed to resume.

For the first Meute run, use **3.1b** as the target once its acceptance criteria are available. [PR #75](https://github.com/bearyjd/meute/pull/75) establishes 3.1a as the merged CLI foundation and names web receipt wiring as 3.1b. A run through **3.4** needs the scope and acceptance criteria for each run-control slice.
