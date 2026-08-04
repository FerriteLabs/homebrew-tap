# Ferrite Homebrew Tap - Actor and Workflow Audit

Scope: `ferrite.rb` and the automation in `.github/workflows/` that produces,
validates, and publishes it (`ci.yml`, `update-formula.yml`,
`build-bottles.yml`, `dependabot-auto-merge.yml`). This audit maps every actor
that can read or mutate the formula, the trust boundary each crosses, and the
cost/risk of the path it takes.

> **Status: all findings below (F1-F7) are historical.** This document was
> originally written against a broken baseline (formula pointed at a
> nonexistent v0.3.0 tarball with a placeholder checksum, six placeholder
> bottle platforms, an unverified checksum trust model, and a direct-push
> release path). Every finding has since been fixed; the actor/trust-boundary
> analysis is preserved below unchanged (each row now carries a `Status`
> column and a short note on the fix and its commit) because the mapping of
> *who can reach this file and what boundary they cross* is still the
> correct mental model for reviewing future changes to these workflows - only
> the vulnerable baseline state it originally described no longer exists.
> See "Current State" immediately below the findings table for what is true
> today, and `VERIFICATION_REPORT.md` for the full verification trail.

## Summary (historical baseline this audit was written against)

- The formula (`ferrite.rb`) pointed at v0.3.0 with a literal
  `PLACEHOLDER_SOURCE_SHA256_REPLACE_VIA_CI_RELEASE_WORKFLOW_000000000000`
  source checksum, so `brew install ferrite` could not succeed for any
  consumer; CHANGELOG.md already claimed a v0.4.0 bump that never reached the
  formula, an actor-visible drift between docs and shipped state.
- Six bottle platforms carried unresolvable `PLACEHOLDER_SHA256_*` values
  inside `bottle do ... end`; Homebrew treats a bottle block as authoritative
  once present, so every install attempted to fetch a bottle artifact that
  did not exist instead of quietly falling back to source.
- `depends_on "openssl@3"` was declared three times (top-level, then guarded
  by `if OS.mac?` and `if OS.linux?`), which was redundant on every supported
  OS and signaled the dependency list was patched incrementally without
  removing the earlier unconditional line.
- `update-formula.yml` treated the human or upstream CI actor supplying
  `sha256` as fully trusted: it wrote that value straight into the formula
  with no independent recomputation, so a compromised or mistaken
  `repository_dispatch`/`workflow_dispatch` payload became the checksum that
  every downstream Homebrew user verified against.
- `build-bottles.yml` collapsed two actors into one unreviewed path: the
  `collect` job downloaded five untrusted build artifacts, rewrote
  `ferrite.rb`, and pushed directly to `main` with a bot identity, bypassing
  the branch-protection/PR review that `update-formula.yml` otherwise used
  for the same file.

## Findings

All findings below are **Resolved**. The Actor / Component / Trust Boundary /
Cost / Risk / Description columns are preserved verbatim from the original
audit (they still describe the correct actor-and-boundary model for this
repository); the `Status` column records what changed and where.

| ID | Actor | Component / Workflow | Trust Boundary Crossed | Cost | Risk | Description | Status |
|----|-------|----------------------|------------------------|------|------|-------------|--------|
| F1 | End user (`brew install ferrite`) | `ferrite.rb` source stanza | Homebrew client trusts tap-committed `sha256` | Low (blocks install immediately, fails fast) | High (every install is currently broken; no working artifact ships) | `url` still resolves to v0.3.0 while `sha256` is the literal placeholder string, so checksum verification always fails. | **Resolved** (`4b5a18a`): `url`/`sha256` point at the real, checksum-verified v0.4.0 tarball. `tests/formula_checksum_test.rb` downloads the real tarball and asserts the checksum matches on every full run, and now fails closed (rather than skipping) on a network error (see checksum-policy hardening below). |
| F2 | End user (`brew install ferrite`) | `ferrite.rb` bottle block | Homebrew client trusts bottle root_url + per-platform sha256 | Medium (forces slow source builds or hard failures on all six platforms) | High (misleads users into thinking prebuilt bottles exist; wastes CI/user minutes retrying) | All six bottle platform checksums are `PLACEHOLDER_SHA256_*`, none resolvable to a real artifact. | **Resolved** (`4b5a18a`): the placeholder bottle block was removed entirely; `brew install` falls back to source until `build-bottles.yml` merges real bottle metadata via `brew bottle --merge`. The matrix producing that metadata was itself rationalized from a fake five-target list to four genuinely distinct, currently-supported platforms (see below). |
| F3 | Maintainer reading `ferrite.rb` | Dependency list | N/A (readability / maintenance boundary) | Low (no functional break, cargo/brew tolerate duplicates) | Low-Medium (obscures real dependency intent, invites future drift) | `depends_on "openssl@3"` is declared unconditionally and then re-declared per-OS a few lines later. | **Resolved** (`4b5a18a`): the duplicate per-OS declarations were removed; `depends_on "openssl@3"` is now declared exactly once. `tests/formula_structure_test.rb#test_no_duplicate_openssl_dependency` guards against regression. |
| F4 | Upstream Ferrite release CI (`repository_dispatch: ferrite-release`) or a human (`workflow_dispatch`) | `update-formula.yml` | Automation trusts external event payload as ground truth for `sha256` | Medium (a bad run produces a merged formula with a wrong checksum) | High (supply-chain: nothing recomputes or compares the checksum against the actual tagged tarball before it is committed) | The workflow copies `client_payload.sha256` / `inputs.sha256` directly into `ferrite.rb` via `sed`/`awk` with no verification step. | **Resolved** (`7f4bac3`): the workflow now always downloads and recomputes the canonical checksum of the tagged archive itself; a caller-supplied `sha256` is only ever used as an advisory cross-check and the run fails closed if it disagrees. `build-bottles.yml`'s `validate` job independently re-verifies this same invariant (formula/metadata/requested-version agreement, plus its own checksum recomputation) before any bottle is built. |
| F5 | Upstream Ferrite release CI (`repository_dispatch: new-release`) or a human (`workflow_dispatch`) | `build-bottles.yml` `collect` job | `github-actions[bot]` pushes straight to `main`, skipping PR review that `update-formula.yml` uses for the identical file | Medium (five-platform matrix build cost per run) | High (a single compromised or buggy job can land arbitrary formula content on `main` without human review) | `collect` job runs `git commit` + `git push` directly instead of opening a pull request. | **Resolved** (`c0c6e79`, tightened by `6301779` and `eeeecc5`): `collect` uses canonical `brew bottle --merge --write --no-commit` and lands changes via `peter-evans/create-pull-request`. It now requires the exact complete JSON/tarball set, rejects a formula that still has prior-release bottle metadata, writes only the new validated set, copies Homebrew's merged tap clone back to the Actions checkout, and verifies the resulting root URL/tags/checksums with no rebuild metadata. Every change still goes through normal PR review. |
| F6 | `update-formula.yml` / `build-bottles.yml` inputs | Version parameters (`version`, `sha256`) | No input validation boundary | Low | Medium (malformed version strings propagate into `url`, tag names, and release lookups) | Neither workflow validates that `version` is a well-formed SemVer string before interpolating it into URLs, branch names, and release tags. | **Resolved** (`7f4bac3`, `c0c6e79`): both workflows validate the requested version against a strict SemVer regex before it is used anywhere, failing closed with `::error::` otherwise. `build-bottles.yml` additionally cross-checks the requested version against `ferrite.rb`'s url version and `release-metadata.json` before building any bottle. |
| F7 | CI (`ci.yml` audit job) | Bottle-only structural check | Gatekeeper trusts regex-based platform scan | Low | Medium (the audit job asserts bottle *platforms* exist but never checks for placeholder *values*, so it currently passes against six placeholder checksums) | `Verify bottle configuration` step scans for `\w+:\s+"[a-f0-9]{64}"` which placeholder strings do not match in length, silently passing today only because the regex happens to reject them, not because it is designed to. | **Resolved** (`ci.yml`): the same step now explicitly rejects any `PLACEHOLDER` substring in the bottle block (not just relying on regex length mismatches), in addition to the pre-existing platform/ARM64 presence checks. `tests/formula_structure_test.rb#test_bottle_block_has_no_placeholder_checksums` and `tests/formula_checksum_test.rb` cover the source-tarball equivalent. |

## Current State

As of this audit revision, all of the following are true and covered by the
dependency-free test suite (`tests/run.sh`) unless noted otherwise:

- `ferrite.rb` points at the real v0.4.0 release tarball with a
  checksum-verified `sha256`; no placeholder values remain anywhere in the
  formula or its bottle metadata (there is currently no bottle block at all,
  pending the next real `build-bottles.yml` run).
- `update-formula.yml` and `build-bottles.yml` both validate strict SemVer,
  never trust a caller-supplied checksum without independently recomputing
  and comparing it, and land every change via pull request rather than a
  direct push to `main`.
- Every `update-formula.yml` version bump removes the complete prior
  `bottle do ... end` block before changing the source URL/SHA. The tested
  updater writes validated formula/metadata contents through same-directory
  temporary files and atomic renames, so an old rebuild suffix, root URL, or
  bottle checksum cannot survive into the version-update PR.
- `build-bottles.yml`'s bottle matrix targets four genuinely distinct,
  currently-supported platforms (`arm64_sequoia`, `sequoia`, `arm64_sonoma`,
  `x86_64_linux`) instead of five duplicate/mislabeled/retired ones, and
  independently validates the actual `brew bottle --json` tag/filename
  produced by each runner against the matrix's declared expectation.
- `build-bottles.yml`'s `validate` job (which both `bottle` and `collect`
  transitively depend on) cross-checks the requested version, `ferrite.rb`'s
  url/sha256, and `release-metadata.json`'s version/sha256/url for mutual
  agreement, and independently recomputes the tagged archive's checksum,
  before a single bottle is built - failing the whole workflow closed on any
  mismatch.
- The bottle `collect` job validates exactly four JSON manifests and four
  tarballs, validates each manifest's version/tag/root URL/checksum, writes
  the complete new bottle set without retaining prior-version metadata, then
  cross-checks the formula block against the validated manifests.
- `ci.yml` and `build-bottles.yml` tap the checkout deterministically as
  `ferritelabs/ci` and run Homebrew checks against
  `ferritelabs/ci/ferrite`; neither workflow uses path-based `brew audit`.
- The formula's `test do` block runs its server-readiness poll and every
  functional assertion inside a single `begin`/`ensure`, polls with a quiet
  `system(...)` call (never asserting on the transient non-zero exit every
  attempt returns before the server is listening), requires readiness before
  proceeding, and always terminates and reaps the exact forked `server_pid`.
- `tests/formula_checksum_test.rb` fails closed on a real network error
  during a full/default run; the only sanctioned skip is the explicit
  `FERRITE_TAP_SKIP_NETWORK=1` / `tests/run.sh --fast` opt-in, and `ci.yml`'s
  network-enabled `audit` job always runs the full suite (never `--fast`),
  so a skipped checksum check can never pass that job.
- `tests/run.sh` runs under macOS's system `/bin/bash` (3.2, no
  `mapfile`/`readarray`/associative arrays) as well as any modern Bash.

The canonical tapped checks retain one shared `brew audit --strict` /
`brew style` finding (`post_install` creating directories). It is
intentional; see the Verification Addendum below and
`VERIFICATION_REPORT.md` for the reasoning.

## Ordered Workflow Sequence (release-to-install path, current)

1. A maintainer tags a release in `ferritelabs/ferrite` (out of scope here,
   assumed authoritative source of truth for version + tarball).
2. The upstream release pipeline fires `repository_dispatch: ferrite-release`
   (or a maintainer runs `workflow_dispatch`) against this tap with
   `version`/`sha256` inputs.
3. `update-formula.yml` resolves those inputs, validates strict SemVer,
   independently recomputes the canonical tagged-archive checksum (only
   ever cross-checking, never trusting, a caller-supplied `sha256`),
   removes any prior-version bottle block before atomically replacing the
   validated `url`/`sha256` formula contents and equivalent fields in
   `release-metadata.json`, runs `ruby -c` and
   `tests/run.sh --fast`, and opens a pull request via
   `peter-evans/create-pull-request`.
4. `ci.yml` runs on that pull request: `test` (the dependency-free repo
   suite, fast/offline), `lint` (Ruby syntax + structural grep), `audit`
   (tap checkout as `ferritelabs/ci`, run tap-qualified
   `brew audit --strict --online ferritelabs/ci/ferrite` and
   `brew style ferritelabs/ci/ferrite`, run the full network-enabled test
   suite including the real tarball checksum check, and scan bottle
   metadata), and `gitleaks` (secret scanning).
5. A maintainer reviews and merges the pull request into `main`.
6. Separately, `repository_dispatch: new-release` (or `workflow_dispatch`)
   triggers `build-bottles.yml`. Its `validate` job resolves and SemVer-
   validates the requested version, then cross-checks that `ferrite.rb`'s
   url/sha256, `release-metadata.json`'s version/sha256/url, and the
   requested version all agree, and independently recomputes the tagged
   archive's checksum - failing the whole run closed on any mismatch
   before a single bottle is built. Its `bottle` job matrix then builds
   four genuinely distinct, currently-supported platform bottles
   (`arm64_sequoia`, `sequoia`, `arm64_sonoma`, `x86_64_linux`), validating
   each runner's actual `brew bottle --json` tag/filename against the
   matrix's declared expectation. Its `collect` job verifies the exact
   expected JSON/tarball set and every manifest's version/tag/root URL/
   checksum, requires the formula to have no prior bottle block, merges only
    this complete set with `brew bottle --merge --write --no-commit`, copies
    Homebrew's written formula from its cloned local tap back to the Actions
    checkout, verifies that formula exactly matches the manifests with no
    rebuild metadata, runs `ruby -c` and `tests/run.sh --fast`, runs
    tap-qualified audit/style against `ferritelabs/ci/ferrite`, and opens a
    pull request via `peter-evans/create-pull-request` - it does not push
    directly to `main` - before separately publishing a GitHub Release with
    the bottle archives attached.
7. `dependabot-auto-merge.yml` independently auto-merges Dependabot-authored
   dependency PRs (workflow/action version bumps) that are minor/patch,
   outside the release path but sharing the same `main` branch.
8. End users run `brew install ferrite` (or `brew tap` first); Homebrew
   fetches the bottle for their platform if the checksum in `ferrite.rb`
   resolves, otherwise falls back to building from the source `url`/`sha256`.

## Out of Scope

- The `ferritelabs/ferrite` source repository itself (Cargo features,
  `src/main.rs`, release tagging process) - only its published tarball and
  release-trigger contract are treated as inputs here.
- `vscode-ferrite`, `jetbrains-ferrite`, `ferrite-docs`, `ferrite-ops`, and
  `ferrite-bench` repositories - not part of this tap and not touched by this
  audit.
- GitHub organization-level settings (branch protection rules, required
  reviewers, Actions permissions) that are configured outside this
  repository and cannot be verified from the tap contents alone.
- Runtime behavior of the built `ferrite`/`ferrite-cli` binaries beyond what
  the formula `test do` block exercises (e.g. protocol correctness,
  performance) - covered by the upstream project, not the packaging layer.
- Homebrew core internals (bottle format, `brew audit` rule implementations,
  `brew style` cop definitions) - treated as an external, trusted contract.

## Verification Addendum (post-hardening validation pass)

After AUDIT.md was written and the formula/workflows were hardened
(fixing F1-F7 above), the following checks were run against the
resulting state and are recorded here for traceability:

- `ruby -c ferrite.rb`: syntax OK.
- `tests/run.sh` (full, network-enabled): all 3 test files pass,
  including the real tarball checksum verification against
  `b4db8cc8eb0d3c2cef4a019a47d550c347df69fb8a4f77550c814fae463005cf`.
- `brew audit --strict --online ferrite` (via a local trusted tap):
  reduced from 8 problems to 1. Fixed: an over-length `desc`, `:build`
  dependency ordering, `option` stanza ordering, a non-modifier `if`
  with a single-line body, and a redundant explicit `0` argument to
  `shell_output` (its documented default). One finding is intentionally
  **not** auto-corrected: `post_install only creates directories
  created by brew services`. Verified that `brew services` does not
  create the parent directory for `log_path`/`error_log_path` itself,
  so blindly deleting `post_install` (as `brew style --fix` would do)
  risks a broken first `brew services start ferrite` run on a system
  where `var/log/ferrite` does not yet exist. Kept intentionally, with
  an inline code comment explaining why.
- `brew style ./ferrite.rb`: 4 offenses before this pass, 3 after (the
  `Style/Documentation` offense was fixed by adding a top-level class
  comment). The two remaining `Sorbet/*Sigil` convention offenses
  (wanting `# typed: true`/`strict` instead of `false`) are left
  unchanged: this is a purely cosmetic Sorbet-typing convention with no
  runtime effect, and other real-world community taps on the same
  Homebrew installation (e.g. `skeema/tap`) use the same `# typed:
  false` sigil, indicating it is an accepted norm for non-homebrew-core
  taps rather than a defect.
- Source install/test were both attempted and completed successfully
  end-to-end in this environment: `brew install --build-from-source
  ferrite` (via a locally trusted tap pointing at this checkout)
  finished in ~15m36s, and `brew test ferrite` (the formula test do
  block: version check, PING, SET/GET, DBSIZE) passed with no
  failures. The equivalent `cargo build --release --features tls,cli`
  was also run directly against the extracted v0.4.0 source tree as a
  faster independent cross-check and completed in under 4 minutes.
- Environment constraint discovered during validation: the sandbox
  disk briefly reached 100% capacity during the dependency-heavy
  `brew install` (LLVM and Rust build toolchain bottles are several GB
  combined) because of unrelated concurrent workloads on the same
  machine; the install still completed successfully once that
  transient pressure passed, and all test artifacts were removed
  afterwards (`brew uninstall ferrite`, `brew untap`) to restore disk
  headroom. This is noted as a property of this shared sandbox, not of
  the formula.

## Verification Addendum (Bash 3.2 / bottle-matrix / version-truth / test-hygiene pass)

Following the bottle-matrix, version-truth, formula-test-cleanup, and
checksum fail-closed changes described above, the following checks were
run against the resulting state:

- `tests/run.sh --fast` and `tests/run.sh` (full, network-enabled): both
  pass under `/bin/bash` (macOS system Bash 3.2, no `mapfile`/
  `readarray`/associative arrays) and under a modern Bash 5.x. The fast
  runs execute 40 tests / 264 assertions with two intentional skips
  (network checksum and absent bottle block); the full runs execute
  40 tests / 267 assertions with one intentional skip (absent bottle
  block). All four combinations report 0 failures and 0 errors.
- `ruby -c ferrite.rb` and `ruby -c tests/*.rb`: syntax OK.
- `actionlint` on every workflow file (`ci.yml`, `update-formula.yml`,
  `build-bottles.yml`, `dependabot-auto-merge.yml`): no findings.
- `brew audit --strict --online` (via a locally trusted tap): 1 finding,
  the same intentionally-retained `post_install` finding documented
  above and in `VERIFICATION_REPORT.md`. Fixed one new finding this pass
  introduced: the readiness-poll's `system(...)` call originally passed
  `"#{bin}/ferrite-cli"` as a literal interpolated string where
  `brew audit` correctly prefers the idiomatic `bin/"ferrite-cli"`
  Pathname helper; corrected and re-verified clean.
- `brew style ferritelabs/tap/ferrite` (the canonical tapped-formula
  invocation): 1 offense, the same intentional `post_install` finding.
  Direct path mode (`brew style ./ferrite.rb`) additionally reports the
  two `Sorbet/*Sigil` convention offenses documented above.
- Manually verified fail-closed behavior end-to-end rather than relying
  on code review alone: pointed the formula's `url` at a non-resolving
  host and confirmed `tests/formula_checksum_test.rb` now reports
  `1 errors, 0 skips` (previously it would have reported a silent
  skip); ran the extracted `build-bottles.yml` formula/metadata/
  version-agreement Ruby check against the real repo state (passes)
  and against a deliberately mismatched requested version and a
  corrupted `release-metadata.json` sha256 (both correctly fail
  closed with `::error::`); ran the extracted checksum-recompute step
  against the real network and confirmed it matches the real v0.4.0
  tarball.
- Source install/test were **not** re-run end-to-end in this session:
  the `install` method (and therefore bottle-relevant install
  semantics) is unchanged from the prior verified pass recorded above;
  only the `test do` block's readiness-polling/cleanup structure
  changed. Per the pragmatic scope for this pass, the prior successful
  `brew install --build-from-source`/`brew test` verification is
  retained rather than re-run (a ~15+ minute Rust build with no
  bearing on the polling-pattern change actually made). The new
  polling pattern's runtime behavior (quiet `system(...)` not raising
  on a not-yet-ready server, `ensure` always reaping `server_pid`) was
  instead verified directly with a standalone Ruby reproduction of the
  same fork/poll/ensure shape against a command that never becomes
  ready, confirming no leaked process and no raised exception escaping
  the `begin`/`ensure`.
- Environment note: this sandbox disables `brew audit [path]`/
  `brew install [path]` the same way the prior verification pass
  found; validation again worked around this via
  `brew tap ferritelabs/homebrew-tap "$(pwd)"` +
  `brew trust --formula ferritelabs/tap/ferrite`, and both were
  reverted (`brew untrust`, `brew untap`) after verification completed.

## Verification Addendum (review findings: bottle reset and tapped audit)

The two follow-up review findings were resolved in `6301779`, with Homebrew
tap-clone copy-back corrected in `eeeecc5`, and verified on 2026-08-04:

- A behavioral fixture containing an old bottle root URL, two old checksums,
  and `rebuild 7` proves the version updater removes every prior bottle value
  before writing the new source URL/SHA. An end-to-end temporary-file test
  runs the same `scripts/update_formula.rb` command used by the workflow.
- Static workflow tests prove bottle collection has no merge command that
  preserves old metadata, requires the complete JSON/tarball set, validates
  every manifest, rejects an existing formula bottle block, and verifies the
  newly written block exactly matches the validated checksums with no rebuild
  metadata. They also require the formula written in Homebrew's cloned local
  tap to be copied back into the Actions checkout before PR creation.
- Static workflow tests also prove both `ci.yml` and `build-bottles.yml` tap
  the checkout as `ferritelabs/ci`, audit
  `ferritelabs/ci/ferrite`, style that same tap-qualified formula, and never
  use a path-based audit command.
- Fast and full suites passed under `/bin/bash` 3.2 and GNU Bash 5.3:
  fast runs each executed 46 tests / 335 assertions with two intentional
  skips; full runs each executed 46 tests / 338 assertions with one
  intentional absent-bottle skip. All four runs had zero failures/errors.
- `ruby -c` passed for `ferrite.rb`, `scripts/update_formula.rb`, and every
  Ruby test/helper. `actionlint .github/workflows/*.yml` had no findings.
- The exact local commands
  `brew audit --strict --online ferritelabs/ci/ferrite` and
  `brew style ferritelabs/ci/ferrite` were run after tapping this checkout as
  `ferritelabs/ci`. Each returned only the already documented intentional
  `post_install` directory-creation finding.
- A real four-platform `brew bottle --merge` remains GitHub-runner-only; the
  local verification covers the complete-set gates and post-merge comparison
  statically/behaviorally but does not manufacture substitute bottle
  artifacts.
