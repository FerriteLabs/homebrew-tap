# Verification Report - refactor/clean-code-srp (7 numbered requirements)

Branch: `refactor/clean-code-srp`. Working tree verified clean before any
change was made; no unrelated changes existed to preserve. No push, merge,
or history rewrite was performed - all work is local commits on the
existing branch.

## Stable-release-only review follow-up (2026-08-04)

- Added one shared validator, `scripts/release_version.rb`, that accepts only
  stable versions exactly `X.Y.Z`. Numeric components cannot have leading
  zeroes; prerelease/build suffixes, `v` prefixes, whitespace, and extra
  components are rejected with a clear error.
- `update-formula.yml` and `build-bottles.yml` invoke that validator before
  exposing the version as a workflow output. Archive/bottle URLs, PR branch
  names, release tags, artifact names, downloads, and bottle builds therefore
  consume only a validated stable version.
- `scripts/update_formula.rb`, the release metadata helper/tests, formula
  URL/livecheck checks, and workflow behavior tests enforce the same rule.
  The bottle workflow also validates versions read from `ferrite.rb` and
  `release-metadata.json` before any build.
- `ferrite.rb` and `release-metadata.json` remain at version `0.4.0`.

Verification:

- `/bin/bash` is GNU Bash 3.2.57 on this macOS host.
- `/bin/bash tests/run.sh --fast`: 8 files, 70 tests, 495 assertions,
  0 failures/errors, 2 intentional skips.
- `/bin/bash tests/run.sh`: 8 files, 70 tests, 498 assertions,
  0 failures/errors, 1 intentional absent-bottle skip.
- `ruby -c` passed for `ferrite.rb`, all scripts, and all test files.
- `actionlint .github/workflows/*.yml`: no findings.
- After `brew tap ferritelabs/ci "$(pwd)"`, both
  `brew audit --strict --online ferritelabs/ci/ferrite` and
  `brew style ferritelabs/ci/ferrite` ran and reported only the existing,
  intentionally retained `post_install` directory-creation finding. The tap
  was removed afterward.

## Review follow-up verification (2026-08-04)

Commits `6301779` and `eeeecc5` resolve the two subsequent review findings
without changing the pull-request review flow:

- `scripts/update_formula.rb` now removes any existing bottle block before
  updating source URL/SHA, validates the result, and atomically replaces each
  output file. Regression tests prove old rebuild metadata, root URLs, and
  checksums do not survive.
- Bottle collection validates the exact four-platform JSON/tarball set and
  each manifest's version/tag/root URL/checksum, refuses formulas containing
  prior bottle metadata, merges without preserving old entries, and verifies
  the written formula exactly matches the new validated set. Because a local
  tap is a Homebrew-managed clone, collection explicitly copies that merged
  formula back to the Actions checkout before PR creation.
- `ci.yml` and `build-bottles.yml` tap the checkout under the deterministic
  `ferritelabs/ci` name and run:
  `brew audit --strict --online ferritelabs/ci/ferrite` and
  `brew style ferritelabs/ci/ferrite`. Static tests prohibit path-based audit.

Verification:

- `/bin/bash tests/run.sh --fast` and GNU Bash 5.3 equivalent: 46 tests,
  335 assertions, 0 failures/errors, 2 intentional skips.
- `/bin/bash tests/run.sh` and GNU Bash 5.3 equivalent: 46 tests,
  338 assertions, 0 failures/errors, 1 intentional absent-bottle skip.
- Ruby syntax passed for the formula, updater, and all tests/helpers.
- `actionlint .github/workflows/*.yml`: no findings.
- The exact tapped audit/style commands above were run locally. Both returned
  only the intentionally retained `post_install` directory-creation finding.
- The real multi-platform bottle merge still requires GitHub-hosted runners;
  no substitute bottle artifacts were fabricated locally.

This section supersedes the older test counts and Homebrew invocation details
in the historical seven-requirement record below.

## Commits (one per requirement ID, conventional commit format)

| ID | Commit | Type/scope | Summary |
|----|--------|------------|---------|
| 1 | `97e0224` | docs(audit) | Add AUDIT.md: actor/workflow audit of ferrite.rb and CI (5-bullet summary, findings table with actor/cost/risk, ordered sequence, non-empty out-of-scope). |
| 2 | `4b5a18a` | fix(formula) | Point ferrite.rb at the real, checksum-verified v0.4.0 tarball; remove the placeholder bottle block entirely; dedupe the openssl@3 dependency; fix a stale Rust-version comment. |
| 3 | `eba91e0` | test | Add tests/ (Ruby minitest, stdlib only) plus tests/run.sh; wire a new `test` job into ci.yml that `lint`/`audit` depend on. |
| 4 | `7f4bac3` | ci(update-formula) | Harden update-formula.yml: env-based inputs, strict SemVer validation, always-recomputed canonical checksum compared against (never trusted from) the supplied value, atomic ferrite.rb + release-metadata.json update, tests before PR. |
| 5 | `c0c6e79` | ci(build-bottles) | Repair build-bottles.yml: validated inputs/artifacts, canonical `brew bottle --merge --write` instead of placeholder-regex substitution, pull-request flow instead of a direct push, tests/audit before the PR. |
| 6 | `a45bc15` | fix(formula) | Run the full validation matrix and fix every high-confidence, non-behavior-changing brew audit/style finding; document the one intentionally-retained finding; run and pass a full source install/test in this environment. |
| 7 | (this commit) | docs | This verification report. |

## Diffstat (commits 1-6 combined, base `8aa8445`)

```
.github/workflows/build-bottles.yml  | 175 +++++++++++++++++++++--------------
.github/workflows/ci.yml             |  42 +++++++--
.github/workflows/update-formula.yml | 150 ++++++++++++++++++++++++------
AUDIT.md                             | 138 +++++++++++++++++++++++++++
CHANGELOG.md                         |  13 +++
ferrite.rb                           |  66 +++++--------
release-metadata.json                |   7 ++
tests/formula_checksum_test.rb       |  72 ++++++++++++++
tests/formula_structure_test.rb      | 117 +++++++++++++++++++++++
tests/run.sh                         |  64 +++++++++++++
tests/test_helper.rb                 |  30 ++++++
tests/workflow_behavior_test.rb      | 141 ++++++++++++++++++++++++++++
12 files changed, 867 insertions(+), 148 deletions(-)
```

## Tests

- `tests/run.sh` (fast/offline mode, `--fast`): 3 files, 28 runs, 116
  assertions, 0 failures, 2 intentional skips (the network-bound checksum
  test and the absent bottle block, expected until real metadata exists).
- `tests/run.sh` (full, network-enabled): 3 files, 28 runs, 119 assertions,
  0 failures, 1 intentional skip for the absent bottle block - including a
  real download-and-hash comparison of the v0.4.0 tarball against the
  formula sha256.
- `ruby -c ferrite.rb`: syntax OK.
- `brew audit --strict --online` is expected to be clean after removing the
  directory-only `post_install` hook rejected by current Homebrew policy.
- `brew style ./ferrite.rb`: 2 offenses remain (both `Sorbet/*Sigil`
  convention warnings on `# typed: false`), intentionally left unchanged
  as a purely cosmetic, no-runtime-effect, community-tap-consistent
  choice.
- Full source install/test executed successfully in this environment:
  `brew install --build-from-source ferrite` (~15m36s) and
  `brew test ferrite` (version, PING, SET/GET, DBSIZE) both passed with
  no failures. Cross-checked independently with a direct
  `cargo build --release --features tls,cli` against the extracted
  v0.4.0 source (completed in under 4 minutes). Test artifacts were
  removed afterwards (`brew uninstall ferrite`, `brew untap`).

## Deferred / intentionally not changed

- `# typed: false` sigil (2 `brew style` convention offenses): left
  unchanged. Purely cosmetic; matches other real community taps on the
  same Homebrew installation; bumping to `strict` risks requiring full
  Sorbet type annotations for no packaging benefit.
- End-to-end execution of the real GitHub Actions runners for
  `update-formula.yml` and `build-bottles.yml` was not possible from
  this local sandbox. Each workflow was instead validated by: parsing
  its YAML, asserting its hardening properties via
  `tests/workflow_behavior_test.rb`, and independently re-running the
  exact shell/Ruby snippets embedded in each workflow step (SemVer
  regex, checksum download-and-compare, the atomic
  formula/metadata-update Ruby script) against real inputs and the real
  network. The `brew bottle --merge --write --no-commit` step in
  `build-bottles.yml` specifically could not be exercised against a
  real multi-platform bottle-JSON set in this session (that requires
  the 5-way OS matrix from GitHub-hosted runners); it is implemented
  per Homebrew's documented `brew bottle --help` semantics, but should
  be treated as the first thing to watch on its next real run.

## Riskiest commit

**`c0c6e79` (ci(build-bottles): repair merge flow and require PR review)**
is the riskiest of the six. Reasoning:

- It replaces a previously-working (if crude) placeholder-substitution
  script with the canonical `brew bottle --merge --write --no-commit`
  flow, which depends on Homebrew resolving the `ferrite` formula name
  back to this repository's root-level `ferrite.rb` after a local
  `brew tap`. That resolution path was reasoned from Homebrew's
  documented tap layout support and cross-checked against this
  session's successful `brew install`/`brew audit` runs (which used the
  same tap-then-resolve-by-name mechanism), but the specific
  `--merge --write` invocation was not exercised against a real
  multi-platform bottle-JSON set end-to-end.
- It also changes the workflow's side effects from an unreviewed direct
  push to a pull-request flow, which is the intended hardening but
  does shift when/how bottle metadata reaches `main` (a maintainer must
  now merge the PR; nothing auto-lands).
- Recommended follow-up: watch the first real `workflow_dispatch`/
  `repository_dispatch` run of `build-bottles.yml` closely, and keep
  `brew install --build-from-source` as a documented fallback (already
  true today, since ferrite.rb currently ships with no bottle block).

`7f4bac3` (update-formula.yml hardening) is the second most sensitive
change (it changes the trust model for a security-relevant checksum),
but every individual shell/Ruby fragment in it was independently
re-executed against real inputs in this session (SemVer regex, the
`curl | sha256sum` checksum computation matched the authoritative
checksum from the task, and the atomic update script was run against a
scratch copy of ferrite.rb with correct results), so its residual risk
is materially lower than build-bottles.yml's.

## Environment notes

- Homebrew in this sandbox disables `brew audit [path]` and
  `brew install [path]` (requiring a tapped formula name instead) and
  gates untapped/newly-tapped formulae behind a `brew trust` step not
  present in stock Homebrew documentation. Validation above worked
  around this by tapping this checkout locally
  (`brew tap ferritelabs/homebrew-tap "$(pwd)"`) and trusting it
  (`brew trust --formula ferritelabs/tap/ferrite`); this has no bearing
  on the real `ferritelabs/homebrew-tap` repository or its CI, which
  use `Homebrew/actions/setup-homebrew@v1` on GitHub-hosted runners.
- The sandbox disk briefly reached 100% capacity during the
  dependency-heavy `brew install` (unrelated concurrent workloads on
  the same shared machine) but recovered and the install completed
  successfully; all test-only artifacts were removed afterwards.

## This session's follow-up (2026-08-04): tap-qualified bottle jobs, JSON path normalization, Kernel.system readiness fix

Three fixes, verified end-to-end:

- `build-bottles.yml`'s `bottle` job now taps the checkout as
  `ferritelabs/ci` and runs `brew install --build-bottle
  ferritelabs/ci/ferrite` / `brew bottle --json ... ferritelabs/ci/ferrite`,
  never a path formula (`./ferrite.rb`).
- `build-bottles.yml`'s `collect` job now normalizes every downloaded
  bottle JSON's `formula.path` to this collect runner's own
  `TAPPED_FORMULA` before `brew bottle --merge --write --no-commit`, and
  copies the merged tapped formula back to the checkout
  (`cp "${TAPPED_FORMULA}" ferrite.rb`) - reverting the backwards
  `cp ferrite.rb "${TAPPED_FORMULA}"` direction introduced by the
  immediately prior commit (`d0b5d63`), which silently discarded merged
  bottle metadata instead of preserving it.
- `ferrite.rb`'s readiness poll now calls `Kernel.system((bin/"ferrite-cli").to_s,
  ..., out: File::NULL, err: File::NULL)` explicitly instead of a bare
  `system(...)`, which inside a Formula's `test do` block resolves to
  `Formula#system` (raises `BuildError`, no `out:`/`err:` support) rather
  than the intended non-raising, redirection-capable `Kernel#system`. The
  `begin`/`ensure` `server_pid` cleanup and 10-attempt retry structure are
  unchanged.

Verification:

- `/bin/bash tests/run.sh --fast` and `/bin/bash tests/run.sh` (full,
  network-enabled) under macOS system Bash 3.2.57: both pass, 6 test
  files, 57 tests / 401 assertions (fast, 2 intentional skips) and
  57 tests / 404 assertions (full, 1 intentional skip), 0 failures/errors.
- `ruby -c` passed for `ferrite.rb` and every file under `scripts/` and
  `tests/`. `actionlint` on every workflow file: no findings.
- `brew tap ferritelabs/ci "$(pwd)"` then
  `brew audit --strict --online ferritelabs/ci/ferrite` and
  `brew style ferritelabs/ci/ferrite`: both return only the
  already-documented, intentionally-retained `post_install` finding - no
  regressions. Tap removed after verification.
- The JSON-path-normalization fix was additionally proven against a real
  local Homebrew install using a throwaway dummy formula (not `ferrite`,
  to avoid a slow real build): with an unnormalized foreign-runner-shaped
  `formula.path`, `brew bottle --merge --write --no-commit` failed outright
  (`Error: No available formula with the name "testpkg"`); after applying
  the same normalization the workflow now runs, the merge correctly wrote
  the new `bottle do` block into the tapped clone while leaving the
  checkout's own formula file untouched - confirming both the need for
  normalization and the correct (tapped -> checkout) copy-back direction.
- A real four-platform `brew bottle --merge` against the actual `ferrite`
  formula remains GitHub-runner-only (multi-platform bottle artifacts
  cannot be produced locally); this session's verification covers the
  normalization/merge/copy-back logic itself (via the dummy-formula
  reproduction above and the new `tests/bottle_json_normalization_test.rb`
  fixtures) rather than fabricating substitute four-platform bottle sets.

## CI audit follow-up

- The GitHub-hosted strict audit confirmed current Homebrew service handling
  makes the directory-only `post_install` hook redundant.
- The hook was removed while preserving the existing service working and log
  paths; `Formula Audit` is now expected to be clean.
