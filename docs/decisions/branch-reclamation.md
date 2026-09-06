---
type: Review
title: The three stale branches are squash-merge residue, not unreclaimed work
description: >-
  feat/deploy-verify, feat/cloudflared-profile and fix/verify-profiled-services are patch-identical
  to main (PRs #7/#8/#9); all three are drop, and the "unmerged" flag is an ops/index.py false positive.
status: draft
tags: [homelab, git, branches, squash-merge, ops-index, review]
generated: { by: claude/opus-5, at: 2026-09-04T09:00:00Z }
---

# The three stale branches are squash-merge residue, not unreclaimed work

**Status:** in progress (2026-09-04) — findings recorded; the deletions are Han's call and have
not been made.

## Why — the ask (verbatim)

Not Han's words: this record was produced by a review dispatch. Quoted verbatim from
`repos/ops/dispatch/homelab-review.md`, dispatched 2026-09-04 08:14 UTC by `ops/orchestrator.py`:

> **Verbatim (2026-09-04):** "Three unmerged branches — feat/cloudflared-profile,
> feat/deploy-verify, fix/verify-profiled-services — each 1 commit ahead of main, 11-18d cold,
> flagged by ops/index.py as possible unreclaimed work. For each: what is the commit, is it
> superseded by what has since landed on main, and is it reclaim or drop? Report your findings;
> do not merge or delete anything."

## Discussion

### Verdict: all three are **drop**. Nothing on them is unreclaimed.

Each branch tip is a single commit that was squash-merged into `main` weeks ago, and each is
**patch-identical** to what landed. Nothing was rewritten, dropped, or partially taken during the
squash.

| Branch | Tip | Committed | Landed on main as | PR | Verdict |
|---|---|---|---|---|---|
| `feat/deploy-verify` | `0e1a528` | 2026-08-16 | `a98768a` | [#7](https://github.com/junhyukhan/homelab/pull/7), merged 2026-08-23 | **drop** |
| `feat/cloudflared-profile` | `5e9ab1e` | 2026-08-23 | `b0fa29e` | [#8](https://github.com/junhyukhan/homelab/pull/8), merged 2026-08-23 | **drop** |
| `fix/verify-profiled-services` | `81138a5` | 2026-08-23 | `aa5651b` | [#9](https://github.com/junhyukhan/homelab/pull/9), merged 2026-08-23 | **drop** |

Local and remote tips are the same SHA for all three — no branch carries a local commit that was
never pushed, or a pushed commit missing locally.

**Evidence, not inference.** Three independent checks, all agreeing:

1. `git cherry -v main <branch>` marks every one of the three commits `-` — its patch is already
   upstream by patch-id. This is content equality, and it is the check that survives a squash.
2. `gh pr list --state all` shows PRs #7, #8, #9 `MERGED`, with merge commits `a98768a`, `b0fa29e`,
   `aa5651b` — the three squash commits sitting in `main`'s log.
3. `git diff main <branch>` restricted to the files each branch touched contains no branch-unique
   content. The only `+` lines anywhere in those diffs are *older* forms of lines that #8 and #9
   later replaced — e.g. `feat/deploy-verify` still holds `verify.sh`'s pre-fix
   `docker compose config --services` loop and the SPEC table row for cloudflared from before the
   profile. Restoring any of it would re-open the two defects #8 and #9 closed.

The three commits are also a chain, which is why the older two look "behind" rather than divergent:
#7 added `verify.sh`, #8 gated cloudflared behind the `tunnel` profile (and, per its own message,
broke `verify.sh`'s enumeration), #9 fixed that with `--profile '*'`. `main` holds the end of the
chain. Each branch is simply frozen at its own link.

Deleting these needs `git branch -D` (and `git push origin --delete`); `-d` refuses a squash-merged
branch, on the same ancestry reasoning described below. Deletion stays Han's call — the global
`AGENTS.md` puts branch deletion on the ask-first list, and this dispatch says not to delete.

### The real finding: the flag was a false positive, and it is structural

`ops/index.py:scan_branches` decides "merged" with `git merge-base --is-ancestor <ref> origin/main`
and nothing else. Under this workspace's squash-merge rule a squash writes a *new* commit, so a
merged branch's own commits never become ancestors of `main`. Consequences, both of them permanent
rather than intermittent:

- Every squash-merged branch is reported as `branch_open` — *"unmerged, N commit(s) ahead …
  possible unreclaimed work"*. That is exactly this dispatch: three branches reviewed, three
  false positives.
- The `branch_merged` category is structurally incapable of firing. A checker whose "merged
  branches" count is permanently zero looks identical to a clean workspace.

**This exact defect was already found, diagnosed and fixed — in the other implementation.**
`repos/docs/decisions/git-workflow.md` records it (2026-08-04, *"yes fix the sync script
squash-merge detection"*) and states the fix: rebuild the branch's whole diff against its merge-base
as one synthetic commit with `git commit-tree`, then let `git cherry` answer by patch-id. That fix
lives in `config/claude/.claude/skills/sync-repos/repos-sync.py:185-216` and works. `ops/index.py`
grew its own branch scan on 2026-07-30, five days before the fix, and was edited as recently as
2026-09-04 without ever picking it up — including on 2026-08-08 (`a143263`), which reworked
`scan_branches` to read remote branches and left the ancestry test in place.

So the lesson `git-workflow.md` already wrote down — *"a green check that is structurally incapable
of firing looks exactly like a clean bill of health"* — reproduced itself in a second file. The
record's own `description:` says the check is "now fixed by patch-id probing", which is true of
`repos-sync.py` and false of `ops/index.py`; an agent reading the index would conclude the
workspace has one fixed check rather than one fixed and one broken.

**Out of scope here, deliberately.** The fix is a change to `ops/index.py` in the meta-repo, and
this dispatch is fenced to `homelab/`. Stopping and saying so, per the brief. What a follow-up
dispatch should do: port the `squash_merged()` probe from `repos-sync.py` into `scan_branches`,
report which mechanism matched (ancestry vs. squash) as `repos-sync.py` already does, and amend
`git-workflow.md` — including its `description:` — to say both implementations are fixed.

### Open question for Han

Nothing blocks the deletions. If you want them gone, `/sync-repos` already finds squash-merged
branches correctly (it has the working probe) and offers exactly this cleanup.

## Related records

- `repos/docs/decisions/git-workflow.md` — squash-merge is the workspace rule; the original
  diagnosis and the patch-id fix that `ops/index.py` never received
- `repos/docs/decisions/agent-ops.md` — what `ops/index.py` is for
- [`access-planes.md`](access-planes.md) — the posture `feat/cloudflared-profile` encoded
