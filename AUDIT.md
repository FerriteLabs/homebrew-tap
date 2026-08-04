# Ferrite Homebrew Tap - Actor and Workflow Audit

Scope: `ferrite.rb` and the automation in `.github/workflows/` that produces,
validates, and publishes it (`ci.yml`, `update-formula.yml`,
`build-bottles.yml`, `dependabot-auto-merge.yml`). This audit maps every actor
that can read or mutate the formula, the trust boundary each crosses, and the
cost/risk of the path it takes.

## Summary

- The formula (`ferrite.rb`) still points at v0.3.0 with a literal
  `PLACEHOLDER_SOURCE_SHA256_REPLACE_VIA_CI_RELEASE_WORKFLOW_000000000000`
  source checksum, so `brew install ferrite` cannot succeed for any consumer
  today; CHANGELOG.md already claims a v0.4.0 bump that never reached the
  formula, an actor-visible drift between docs and shipped state.
- Six bottle platforms carry unresolvable `PLACEHOLDER_SHA256_*` values inside
  `bottle do ... end`; Homebrew treats a bottle block as authoritative once
  present, so every install attempts to fetch a bottle artifact that does not
  exist instead of quietly falling back to source.
- `depends_on "openssl@3"` is declared three times (top-level, then guarded by
  `if OS.mac?` and `if OS.linux?`), which is redundant on every supported OS
  and signals the dependency list was patched incrementally without removing
  the earlier unconditional line.
- `update-formula.yml` treats the human or upstream CI actor supplying
  `sha256` as fully trusted: it writes that value straight into the formula
  with no independent recomputation, so a compromised or mistaken
  `repository_dispatch`/`workflow_dispatch` payload becomes the checksum that
  every downstream Homebrew user verifies against.
- `build-bottles.yml` collapses two actors into one unreviewed path: the
  `collect` job downloads five untrusted build artifacts, rewrites
  `ferrite.rb`, and pushes directly to `main` with a bot identity, bypassing
  the branch-protection/PR review that `update-formula.yml` otherwise uses for
  the same file.

## Findings

| ID | Actor | Component / Workflow | Trust Boundary Crossed | Cost | Risk | Description |
|----|-------|----------------------|------------------------|------|------|-------------|
| F1 | End user (`brew install ferrite`) | `ferrite.rb` source stanza | Homebrew client trusts tap-committed `sha256` | Low (blocks install immediately, fails fast) | High (every install is currently broken; no working artifact ships) | `url` still resolves to v0.3.0 while `sha256` is the literal placeholder string, so checksum verification always fails. |
| F2 | End user (`brew install ferrite`) | `ferrite.rb` bottle block | Homebrew client trusts bottle root_url + per-platform sha256 | Medium (forces slow source builds or hard failures on all six platforms) | High (misleads users into thinking prebuilt bottles exist; wastes CI/user minutes retrying) | All six bottle platform checksums are `PLACEHOLDER_SHA256_*`, none resolvable to a real artifact. |
| F3 | Maintainer reading `ferrite.rb` | Dependency list | N/A (readability / maintenance boundary) | Low (no functional break, cargo/brew tolerate duplicates) | Low-Medium (obscures real dependency intent, invites future drift) | `depends_on "openssl@3"` is declared unconditionally and then re-declared per-OS a few lines later. |
| F4 | Upstream Ferrite release CI (`repository_dispatch: ferrite-release`) or a human (`workflow_dispatch`) | `update-formula.yml` | Automation trusts external event payload as ground truth for `sha256` | Medium (a bad run produces a merged formula with a wrong checksum) | High (supply-chain: nothing recomputes or compares the checksum against the actual tagged tarball before it is committed) | The workflow copies `client_payload.sha256` / `inputs.sha256` directly into `ferrite.rb` via `sed`/`awk` with no verification step. |
| F5 | Upstream Ferrite release CI (`repository_dispatch: new-release`) or a human (`workflow_dispatch`) | `build-bottles.yml` `collect` job | `github-actions[bot]` pushes straight to `main`, skipping PR review that `update-formula.yml` uses for the identical file | Medium (five-platform matrix build cost per run) | High (a single compromised or buggy job can land arbitrary formula content on `main` without human review) | `collect` job runs `git commit` + `git push` directly instead of opening a pull request. |
| F6 | `update-formula.yml` / `build-bottles.yml` inputs | Version parameters (`version`, `sha256`) | No input validation boundary | Low | Medium (malformed version strings propagate into `url`, tag names, and release lookups) | Neither workflow validates that `version` is a well-formed SemVer string before interpolating it into URLs, branch names, and release tags. |
| F7 | CI (`ci.yml` audit job) | Bottle-only structural check | Gatekeeper trusts regex-based platform scan | Low | Medium (the audit job asserts bottle *platforms* exist but never checks for placeholder *values*, so it currently passes against six placeholder checksums) | `Verify bottle configuration` step scans for `\w+:\s+"[a-f0-9]{64}"` which placeholder strings do not match in length, silently passing today only because the regex happens to reject them, not because it is designed to. |

## Ordered Workflow Sequence (release-to-install path)

1. A maintainer tags a release in `ferritelabs/ferrite` (out of scope here,
   assumed authoritative source of truth for version + tarball).
2. The upstream release pipeline fires `repository_dispatch: ferrite-release`
   (or a maintainer runs `workflow_dispatch`) against this tap with
   `version`/`sha256` inputs.
3. `update-formula.yml` resolves those inputs, rewrites `url` and the source
   `sha256` in `ferrite.rb`, and opens a pull request via
   `peter-evans/create-pull-request`.
4. `ci.yml` runs on that pull request: `lint` (Ruby syntax + structural
   grep), `audit` (`brew audit --strict --online` plus the bottle-platform
   regex check), and `gitleaks` (secret scanning).
5. A maintainer reviews and merges the pull request into `main`.
6. Separately, `repository_dispatch: new-release` (or `workflow_dispatch`)
   triggers `build-bottles.yml`; its `bottle` job matrix builds five
   platform bottles, and its `collect` job merges the resulting JSON,
   rewrites the bottle `sha256` values in `ferrite.rb`, commits, and pushes
   directly to `main`, then publishes a GitHub Release with the bottle
   archives attached.
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
