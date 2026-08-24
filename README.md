# cic-factory-core

The reusable core of the CIC agent factory: job lifecycle, machine gates, and
agent-run tooling — extracted from
[`CentralInfraCore/cic-factory`](https://github.com/CentralInfraCore/cic-factory)
with history preserved.

The split follows one question per repo:

| repo | question it answers |
|---|---|
| `cic-factory-core` | what can the factory do in general? |
| `cic-factory` | how does CIC use it? |

## Status: round-one extraction, not yet a product

This repository holds the **CIC-coupled code as it stands today**, moved over
unchanged. Nothing was generalised, renamed, or restructured. The paths are the
ones the files had in `cic-factory`.

That is deliberate: the first split is history-preserving only, so that the
generalisation work that follows has a verifiable starting point rather than a
rewrite nobody can diff against.

**Do not depend on this repository yet.** There is no release, no contract, no
stability promise.

## What came over

The pre-SPEC defined the core as three things — tooling, the job schema, and
the lifecycle convention. All three are here.

**Implementation**

```
tools/run-job.sh                job lifecycle driver
tools/check-sequences.sh        the SPEC use-case contract matches the code
tools/measure-concurrency.sh    barrier-based concurrency measurement (not a gate)
tools/measure-close-binding.sh  what the close does and does not bind (not a gate)
tools/measure-executor-boundary.sh  what is still Claude-shaped in the core (not a gate)
tools/validate-spec.sh          pre-run machine gate (K1, K3, K4, K7, K7b, K8, K9, K10, K11)
tools/validate-output.sh        pre-merge machine gate (O1–O5)
tools/update-index.sh           job state map regeneration
tools/test-run-job-finalizer.sh finalizer test
tools/init-hooks.sh             git hook installation
tools/git_hook_commit-msg.sh    Vault commit signing hook
tools/install-claude-hooks.sh   agent hook installation
tools/cic-hooks.json            agent hook configuration
tools/hooks/                    context monitor, event log, no-ask-human guard
tools/env.sh.example            environment template
```

`validate-spec.sh` implements the machine-checkable part of the spec checklist.
Three of the reviewer's criteria are judgement calls that no grep decides, so
they have no gate rule and stay in `/job-validate`, marked `kézi`. The docs used
to describe the gate as covering the whole range; `check-docs.sh` now refuses
that claim.


**Interface** — the operator's entry point to the lifecycle

```
.claude/commands/job-create.md    create a job spec
.claude/commands/job-validate.md  run the spec gate
.claude/commands/job-run.md       run a job
.claude/commands/job-review.md    review delegation
.claude/commands/job-close.md     close a job
.claude/commands/job-boot.md      orchestrator boot sequence
```

**Specification** — the lifecycle convention the tooling implements

```
SPEC.md                         roles, job lifecycle, the state machine,
                                the lease, "git is the source of trust",
                                the three machine gates
CLAUDE.md                       how to work on this repository
docs/onboarding.md              how the model is used in practice
jobs/.schema/meta.yaml          job spec schema — the single definition
.gitignore
```

`CLAUDE.md` arrived whole from `cic-factory` and has since been split: `SPEC.md`
carries the model, the CIC-specific half (ecosystem map, repo paths, MCP server,
reviewed threads) stayed behind in `cic-factory`, and what remains here is how to
develop this repository.

The schema is defined in exactly one place. It used to be restated in prose, and
the restatement fell three fields behind — `lease_expires`, `spec_gate`, `usage`.
The gate now refuses any document that redefines it.

`tools/relay-build-test.sh` was **not** extracted: it drives a CIC-Relay build
and is workflow, not core.

## Known coupling — what round two has to break

The extracted files still reference CIC-specific names. Measured across the
tracked set, excluding this README and `LICENSE.md`, which describe the
coupling rather than carry it:

| coupling | where |
|---|---|
| `cic-factory` repo name | `docs/onboarding.md`, 3 slash commands, `tools/hooks/context-monitor.sh`, `tools/env.sh.example`. **No longer in `tools/run-job.sh`** — the clone source is derived from the repository's own `origin`. |
| `kb_focus` (KB node ids) | `CLAUDE.md`, `docs/onboarding.md`, 2 slash commands, both gates, `tools/run-job.sh`, `jobs/.schema/meta.yaml` |
| `~/.claude-personal` agent layout | `CLAUDE.md`, `docs/onboarding.md`, `.claude/commands/job-run.md`, `tools/run-job.sh`, `tools/install-claude-hooks.sh`, `jobs/.schema/meta.yaml` |
| `CIC-Relay`, `$CIC_RELAY_PATH` | `CLAUDE.md`, `docs/onboarding.md`, `.claude/commands/job-boot.md`, both gates, `tools/env.sh.example`, `jobs/.schema/meta.yaml` |
| `cic-graph` MCP server | `CLAUDE.md`, `docs/onboarding.md`, 2 slash commands, `tools/run-job.sh` |
| `$CIC_MCP_*` | `CLAUDE.md`, `tools/run-job.sh`, `tools/env.sh.example` |
| `cic-my-sign-key` Vault key | `CLAUDE.md`, `tools/git_hook_commit-msg.sh` |
| `CIC-Schemas`, ProofTrace | `CLAUDE.md`, `tools/env.sh.example` |

Each of these is a place where the core currently knows something only CIC
should know.

## What the gate proves, and what it does not

## What this needs from the machine

Linux with the GNU userland. The scripts use `date -d`, `tar --sort`,
`find -printf` and `stat -c`; on a BSD or macOS toolchain those flags mean
something else or do not exist. `tools/check-dependencies.sh` lists the full set
(`--list`) and verifies it, and the gate runs it — so this is checked, not
assumed.

`.github/workflows/gate.yml` checks that the shell, YAML, JSON and Python parse,
that shellcheck finds no error-severity defects, that `LICENSE` is unmodified,
and it runs the behavioural suites below. Their numbers are checked against
this table by `tools/check-suite-counts.sh`, because a count nobody verifies
drifts:

| suite | what it covers |
|---|---|
| `tools/test-run-job-finalizer.sh` | the finalizer trap: SIGPIPE, SIGTERM, closed stdout, never leaving `meta.yaml` claiming `running` when nothing runs, and never pushing a corrected meta beside an index that still says running, never sweeping a foreign staged file into its commit, and never taking back a job another attempt now owns (24 checks) |
| `tools/test-lifecycle-transitions.sh` | the state transition `run-job.sh` performs, and the invariant that it can never write `done` (6 checks) |
| `tools/test-close-job.sh` | every refusal in `close-job.sh` — wrong status, failing output gate, missing/empty/unfinished review, an unacknowledged spec-gate bypass, a bypass hidden behind a YAML comment, an unknown gate value, malformed and duplicate-keyed metas, and a review that belongs to another attempt — each against a fixture that violates it (60 checks) |
| `tools/test-run-job-spec-gate.sh` | that `run-job.sh` refuses a NO-GO spec, that `--skip-spec-gate` still starts, and that the bypass is recorded in `meta.yaml` (15 checks) |
| `tools/test-install-claude-hooks.sh` | that the hook installer converges — running it five times leaves the same file — and does not touch hooks it does not own (10 checks) |
| `tools/test-stale-jobs.sh` | that a job stuck in `running` past its lease is detected, against fixtures that are stuck on purpose, including a status hidden behind a trailing comment (18 checks) |
| `tools/test-check-docs.sh` | that the docs checker itself can fail — broken links, schema duplication, and files not yet added to git — against fixtures that violate each, plus the two drift rules: a suite with no README row, a README row with no file, a documented gate rule that does not exist, an *enforced* rule that no command documents, and an adopting repository judged by a suite table it has no reason to carry (33 checks) |
| `tools/test-check-sequences.sh` | that the sequence-contract checker can fail — a use case missing any of its five parts, a `még nem` status with no issue to return to, and a documented `done` path that names no output gate or no review artifact (28 checks) |
| `tools/test-check-suite-counts.sh` | that the count checker can fail — a suite reporting more checks than the table declares, a row naming a file that is gone, a README with no declared counts at all, and the same case in an adopting repository, where it is not an error (11 checks) |
| `tools/test-check-licence.sh` | that the licence checker can fail — a modified line inside the AGPL text, a removed section 7 separator, a term present in one file and not the other — while an addition *after* the separator is allowed, which is the point (12 checks) |
| `tools/test-check-dependencies.sh` | that the dependency checker can fail — each required command hidden from `PATH` in turn, a missing Python module, and a `date` without GNU `-d` (27 checks) |
| `tools/test-run-job-e2e.sh` | **a whole job, `pending` → `awaiting_review` → `done`**, driven by the `echo` runner — no agent, no network, no cost (17 checks) |
| `tools/test-validate-meta.sh` | that the meta schema rejects what it should — a typo'd field name, an invalid `status`, an empty model, a missing block, a bad `job_id`, a schema that is itself malformed (17 checks) |
| `tools/test-verify-signatures.sh` | that the signature verifier can fail — tampered tree, missing metadata, forged signature, a merge smuggling content, an empty range, an unknown manifest version, a submodule swap that the old tar digest could not see, and a release tag on a hollow merge chain — while a release tag on a content-free merge (single-hop and chained) resolves through to the signed commit and passes, which is how every real release tag actually looks (34 checks) |
| `tools/test-check-embedded-python.sh` | that the embedded-Python checker can fail — the `core/@v0.1.1` indentation error put back, an error behind a backslash-continued command, a Python heredoc hidden behind a non-`PY` delimiter, and a line that merely mentions `python3` without calling it (16 checks) |
| `tools/test-context-monitor.sh` | that the context-monitor hook cannot be made to execute a command — a counter, an evacuation timestamp and a debug log line each carrying a command substitution, plus a symlinked state file a state directory that is private and not in `/tmp`, and two fresh debug logs in one agent config where it declines to guess rather than reporting another job's number (22 checks) |
| `tools/test-meta-get.sh` | that one document reads the same whichever way it is written — quoted, bare, single-quoted, with a trailing comment — and that a duplicate key, malformed YAML or a non-scalar field fails closed rather than looking absent (19 checks) |
| `tools/test-meta-set.sh` | that a field is written to the section it belongs to and nowhere else, that hand-written comments survive, and that a duplicate key or malformed document is refused rather than half-written (50 checks) |
| `tools/test-update-index.sh` | that the generated index says what the metas say — the right field from the right section, a status with a trailing comment read cleanly, a job stuck past its lease flagged, and an unreadable meta listed rather than dropped (25 checks) |
| `tools/test-commit-msg-signer.sh` | that the signer refuses rather than downgrading — no CA, a non-https endpoint, no token, an unreachable Vault — that the token reaches curl through a 0600 config file rather than the process list, and that the signed block names its manifest version (28 checks) |
| `tools/test-resign-on-rebase.sh` | that a rebased branch can be made verifiable again — every commit on a rebased branch stops verifying, `resign-range.sh` restores all of them without truncating an author's own `---`, it refuses a dirty tree and an unresolvable upstream, and the `post-rewrite` hook warns after a rebase or a `--no-verify` amend but stays silent when nothing is stale (26 checks) |
| `tools/test-check-hook-provenance.sh` | that the hook actually in effect is the signer this repository ships — a symlink and an identical copy pass, a stale copy, a wrapper calling something else, a hook that exits 0 without signing, one that keeps the manifest label but changes the computation, and a `core.hooksPath` shadowing a correct `.git/hooks` are each refused; `init-hooks.sh` refuses to install where git would ignore it, and verifies after installing (31 checks) |
| `tools/test-sign-release-tag.sh` | that a release tag itself carries a Vault signature binding its name, target commit, tagger and message — the real signer runs against a real `git tag -a` and the real verifier reads it back; retargeting, message tampering, an already-existing tag, an unresolvable target, an empty message, a message that already contains a signing block, and the author's own `---` are each handled correctly, while an old tag with no tag-level signature still passes on the content-commit check alone (28 checks) |
| `tools/test-proof-binding.sh` | that a signature cannot be transplanted — the real hook signs a real commit and the real verifier reads it back; a block moved to another commit, a rewritten message, a rewritten message, a changed author and a changed committer are each refused, while an amend, merges, editor comments under both cleanup modes, and a `---` of the author's own still verify (33 checks) |
| `tools/test-run-job-boundaries.sh` | that an exported secret named in `input.md` never reaches the prompt, that `$ref`/`$schema` in a spec are left alone instead of being blanked, and that an identifier which would build a path outside `jobs/` is refused before anything is deleted, that a `kb_focus` list is read whatever quoting it uses, and that a variable which is set but not allowlisted is reported rather than silently left literal, and that the job — not a hardcoded path — says where its agent configuration lives (52 checks) |
| `tools/test-push-reconciliation.sh` | that a rejected push is reconciled rather than swallowed — the remote moved on an unrelated path, the job was reassigned underneath, and the message that used to claim the feature branch was pushed no matter what (19 checks) |
| `tools/test-commit-scope.sh` | that a lifecycle commit carries only its own job's paths — another job's meta staged first, a foreign file at the repo root, and the staged change left where it was (11 checks) |
| `tools/test-same-job-guard.sh` | that starting a job which is already running refuses explicitly rather than by accident — a live lease, an expired one, a missing one, an unparseable one, and `--force` taking it over on purpose (26 checks) |
| `tools/test-run-identity.sh` | that a run writes its own `run_id` and a rising `attempt`, that the finalizer refuses to take back a job another attempt now owns, and that `pending → running` stops when the state changed underneath (17 checks) |

Every step was measured against a deliberately broken copy before it landed,
because a gate that cannot go red is decoration. That measurement is not a
formality: the finalizer suite passed 15/15 against a `run-job.sh` sabotaged to
close jobs as `done`, because it only extracts the prelude and the status
decision lives below it. The lifecycle suite exists to cover that blind spot.

There **is** now a test that runs a whole job — `test-run-job-e2e.sh`, made
possible by the `echo` runner. It found a defect on its first run that every
other gate had missed: a Python indentation error in `run-job.sh`'"'"'s
finalisation block, shipped in `core/@v0.1.1`, which crashed every job at the
moment it should have reached `awaiting_review`. Eight suites checking decisions
in isolation could not see it; one test that ran a job saw it immediately.

What the gate still does not prove: that a *real* agent run works. The echo
runner exercises the lifecycle, not Claude.

## Signatures are verified, not just written

The `commit-msg` hook signs every commit against a deterministic digest of its
tree. Until `tools/verify-signatures.sh` existed, **nothing read those signatures
back** — they were a claim, not evidence.

The gate now verifies every commit a PR introduces: the recorded digest must
equal a fresh digest of the tree, and the ECDSA signature must verify against the
certificate embedded in the same message. Verification is offline; the
certificate travels with the commit, and the signing token could not verify
anyway — its policy grants `transit/sign` but not `transit/verify`.

Merge commits are made server-side by GitHub, where no hook runs, so they cannot
be signed. They are held to a different rule instead: **a merge must introduce
nothing** — its tree has to equal one of its parents'. That preserves the actual
invariant, that every byte is covered by some signed commit, without pretending
the merge itself is signed. A merge that does introduce content must be signed
like anything else.

A release tag must point at a signed commit, never at a merge commit.

## A note on the commit signatures

Commits in `cic-factory` carry a Vault signature over the **full repository
tree**. A path-filtered history does not reproduce that tree, so those
signatures no longer verify here — 33 of the 43 extracted commits were
affected.

They were removed rather than carried over, because a signature that cannot
verify is worse than no signature: it reads as provenance. Each affected commit
message instead names its original signed commit in `cic-factory`, where the
signature still holds.

Commits made in this repository are signed normally and verify against their
own tree.

## Releases

| tag | jegyzet |
|---|---|
| `core/@v0.4.0` | [docs/RELEASE-0.4.0.md](docs/RELEASE-0.4.0.md) — the signature binds the commit context and the release tag itself; the tag it ships as is signed with the new tool. **The first tag-level signature; no forced migration** |
| `core/@v0.3.0` | [docs/RELEASE-0.3.0.md](docs/RELEASE-0.3.0.md) — M1 through measurement. **The close now commits, and a review must name its run** |
| `core/@v0.2.1` | [docs/RELEASE-0.2.1.md](docs/RELEASE-0.2.1.md) — fixes three failures that only appear in an *adopting* repository. **Adopt this, not v0.2.0** |
| `core/@v0.2.0` | [docs/RELEASE-0.2.0.md](docs/RELEASE-0.2.0.md) — an audit carried through; M0 complete. **Adopting it needs a `tools/env.sh` change** |
| `core/@v0.1.0` | [docs/RELEASE-0.1.0.md](docs/RELEASE-0.1.0.md) — the first release |

Each note carries a "what it does not guarantee" section. That half is the one
worth reading before building on it.

## Licence

**AGPL-3.0-or-later**, with an attribution term under section 7(b) — the common
core stays open, including for network use, while products built against its
contract boundary stay free. See [`LICENSE.md`](LICENSE.md) for why this differs
from the CC BY-NC-SA 4.0 licence most CIC repositories inherit.
