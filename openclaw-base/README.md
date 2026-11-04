# Source-built OpenClaw base

The Compliance Claw image can use a **Claw-built derivative** of OpenClaw as its
base, in place of the official `ghcr.io/openclaw/openclaw` image. The derivative
has two parts:

- the exact upstream source: `openclaw/openclaw` at the commit in `inputs.env`,
  with the archive SHA-256 pinned;
- plus the reviewed dependency overrides and lock in this directory.

The upstream Dockerfile is not changed. It builds to its own final stage.

**What this base is not:**

- It is not an official OpenClaw image.
- It has no OpenClaw signature and no OpenClaw build attestation.
- Its BuildKit provenance and SBOM are unsigned records of the Claw build, not
  proof of a publisher.
- It is not a customer release.

**Identity in the image:**

- The image labels keep the source origin (upstream `org.opencontainers.image.*`
  labels, `revision`, `version`) separate from the builder identity
  (`ai.pretorin.openclaw-base.*`: derivative flag, source, workspace and lock
  hashes, build run, builder commit).

**Why a separate base:**

- The upstream final stage starts from a clean `node:…-bookworm-slim`. It copies
  `dist` and `node_modules` only from the same build.
- So no official OpenClaw layer, older `node_modules` or older control-ui asset
  is below the new dist.
- The Claw build stays light. The heavy OpenClaw build runs only when these
  inputs change.

## Status on master

- This support is inert. On master, the Claw image still uses the official
  OpenClaw **2026.10.5** image (Dockerfile lines 70 and 128).
- The base targets OpenClaw **2026.10.10**, the runtime that the #71 branch
  introduces. Nothing here changes the image on master.
- The order is:
  1. this support on master;
  2. the reviewed combined lock (r3 + Seroval + joi), in a separate reviewed
     commit after the age boundary;
  3. dispatch and receipt review;
  4. the `FROM` promotion, together with #71.
- Some items below exist only on the #71 branch, not on master: the `qs` and
  `undici` rows of a `pnpm-corrections` step, the `NPM_UNDICI_*` and
  `NPM_IP_ADDRESS_*` keys, and the replacement of npm's bundled `undici` and
  `ip-address`.
- **Build context and cache limit.** The claim is: no runtime pin change, no
  runtime behavior change, and no change to the files of the final stage. It
  is not a claim that a rebuilt image is byte-identical.
  - `.dockerignore` allows `scripts/`. The CLI verification stage copies all
    of `scripts/` (`COPY scripts/ scripts/`).
  - So `scripts/openclaw-base-guard.py` and `scripts/test-openclaw-base.sh`
    enter the build context and that stage's cache inputs.
  - The final stage takes only the verified `pretorin` binary from that stage,
    and it copies specific named scripts, so these host tools are not
    shipped.

## Files

| File | Purpose |
| --- | --- |
| `inputs.env` | Exact source, file hashes, diff and result hashes, build arguments, tool pins, target name. The `LOCK_*` values stay empty until the combined lock is reviewed. The workflow refuses to build while they are empty. |
| `workspace.diff` | The reviewed override set in `pnpm-workspace.yaml` (see below). It changes only the `overrides:` block (`openclaw-base-guard.py policy`). Line 5 is a single space: the context line of a blank upstream line. The patch needs it, so `git diff --check` reports it; do not strip it. |
| `lock.diff` | The combined lock. It does not exist yet (see "joi boundary"). |
| `regenerate-lock.sh` | Makes the combined lock ONCE with the reviewed r3 method: the pinned `node:24.22.1-bookworm` image, corepack pnpm from `packageManager`, `pnpm install --lockfile-only --ignore-scripts`. It refuses before `LOCK_NOT_BEFORE`. `REGEN_DRY_RUN=1` verifies all inputs and stops before pnpm. |
| `forbidden-store-entries.txt` | Store entries that must not exist in the base or in the Claw image. |
| `receipts/<tag>/` | The reviewed receipt of one base build (added at promotion step 3). |
| `../.github/workflows/openclaw-base.yml` | Build and publish (master only). |
| `../scripts/openclaw-base-guard.py` | Collect, compare, policy, lock-change, OCI and diffID checks, with `--self-test`. |
| `../scripts/test-openclaw-base.sh` | Checks a built Claw image against the receipt. |

## The override set

This is one complete reviewed set: experiment 2 r3, plus Seroval 1.6.11, plus
joi 18.3.1. The workspace result of each step is:

| Step | `pnpm-workspace.yaml` SHA-256 |
| --- | --- |
| upstream `v2026.10.10` | `5af51204…` |
| plus r3 overrides (`ce278eb7…`): dompurify 3.4.17, markdown-it 15.0.3, mermaid 12.2.0, `undici@8.11.2` → 8.12.2, ip-address 10.7.4, qs 6.16.1 | `f30c0bfd…` (reviewed) |
| plus Seroval (`seroval: 1.6.11`) | `43a3622a…` (reviewed) |
| plus `joi@18.2.9: 18.3.1`, and the r3 experiment comment replaced by a product comment | `43cc82fd…` (`workspace.diff`, `0f1a3314…`) |

- The only non-functional change against the reviewed chain is the two comment
  lines. The file ships in the image (`/app/pnpm-workspace.yaml`), so it must
  not call the set an experiment.
- The age, trust and exclude rules are unchanged:
  `minimumReleaseAge: 10080`, `minimumReleaseAgeStrict: true`, and the same
  `minimumReleaseAgeExclude`.
- mermaid 12.2.0 (with KaTeX 0.18.10) is part of the r3 set. The KaTeX runtime
  is not exercised by the checked render path. The final qualification keeps
  that limit visible.

## joi boundary

- joi 18.3.1 was published at 2026-10-28T09:59:49.641Z.
- The strict 10,080-minute release age therefore admits it at
  2026-11-04T09:59:49.641Z, so `LOCK_NOT_BEFORE` is `2026-11-04T09:59:50Z`.
- The combined lock cannot exist before then, and no exception is made.

After the boundary:

1. Run `openclaw-base/regenerate-lock.sh <new dir>` once.
2. Review `lock.diff`, `package-changes.txt`, `lockfile-only.log` and
   `sha256.txt`. Expected package changes: the r3 list (`argparse` 3.0.2→3.0.4,
   `commander@8.3.0` removed, dompurify, ip-address, katex, markdown-it,
   mermaid, qs and `undici@8.11.2`), plus `seroval@1.6.8`→`1.6.11` and
   `joi@18.2.9`→`18.3.1`. Any other change must be explained.
3. Commit `lock.diff` and the two `LOCK_*` hashes in **one separate commit**,
   and stop for review.

## Promotion order

A `workflow_dispatch` workflow runs only after it reaches the default branch.
So the order is fixed:

1. **Support lands on master.**
   - Contents: this directory, the workflow, the guard, and the guard's
     fixture self-test in `build.yml`.
   - The reviewed combined lock follows in a separate reviewed commit, because
     it cannot exist before the joi boundary. Until it is there, the `LOCK_*`
     values stay empty and the workflow refuses to build.
   - The Dockerfile keeps its official `FROM` pins (lines 70 and 128; 2026.10.5
     on master). The Claw image does not change.
   - **Prerequisite before any dispatch with `publish: true`:** a repository
     administrator creates the `openclaw-base-publish` environment with a
     required-reviewers rule (at least one reviewer) and "Prevent
     self-review".
     - GitHub creates a referenced environment that does not exist yet, with
       no protection rules, and runs the job at once.
     - So the publish job reads the environment first (REST "Get an
       environment", which needs `actions: read`). It refuses unless both
       rules are present, or if the read fails.
2. **Dispatch** `openclaw-base.yml` on master with `publish: true`.
   - The `build` job runs on `ubuntu-24.04` (the standard public 16 GB runner),
     with `contents: read` only. It uploads the OCI archive and the receipt.
   - The build runs once. Every check runs on the image loaded from that
     archive:
     - each manifest, config and layer is used only after its size and
       SHA-256 match its descriptor;
     - the loaded image ID must equal the archive's config or manifest
       digest, which binds the full image config, not only the layers;
     - the index must carry SLSA provenance and SPDX SBOM attestations;
     - publish pushes that same archive and checks the pushed index digest.
   - The `publish` job (`packages: write` plus `actions: read`) waits for the
     `openclaw-base-publish` environment approval.
   - It refuses if the environment is unprotected.
   - Nothing is pushed before that approval, and publish pushes only the
     archive that `build` checked.
   - The tag is pushed only when the registry answers MANIFEST_UNKNOWN or
     NAME_UNKNOWN for it. An existing tag must already name the same digest.
     Any other error (network, authentication, `denied`) refuses, so a
     transient error cannot move a tag. If GHCR answers `denied` for a package
     that does not exist yet, the first publish refuses and needs a review.
   - Keep failed runs. Do not retry on another runner or with other memory
     settings.
   - A run with `publish: false` is a build-only rehearsal. Its output is never
     pushed later, because a new run can produce different floating bytes
     (below).
3. **Receipt review** before the approval.
   - Commit `receipts/<tag>/` with the small files: `receipt.env`,
     `facts.json`, `oci.json`, `pnpm-store.txt`, `dpkg.txt`,
     `rootfs-diffids.txt`, `official-diffids.txt`, `node-slim-diffids.txt`,
     `build-command.txt`.
   - The full `dist.sha256` and `node-modules.sha256` manifests stay in the run
     artifact (30 days). The receipt binds their hashes.
   - The review checks:
     - the dist manifest against the r3 `overrides-no-joi` manifest: every
       difference comes from Seroval or joi bundling, or from the two build
       stamps; then the actual manifest is bound;
     - the store list against the expected package changes;
     - the forbidden-entry, layer and version-surface results (the build job
       already enforces them);
     - the attestation manifest (unsigned provenance and SBOM present);
     - the recorded dpkg and global npm facts (version, bundled packages,
       manifest hash);
     - the base findings (`trivy-base-all.json`), with each finding mapped to
       the Claw correction that handles it, or reported as open. No exception
       is added.
   - Package visibility (public pull for PR CI) is set only at this review.
4. **FROM-bump commit, together with #71** (its OpenClaw 2026.10.10 runtime
   changes). One commit:
   - both `FROM` lines become `ghcr.io/pretorin-ai/compliance-claw-openclaw-base:<tag>@<top_digest>`;
   - the `qs` and `undici` rows of #71's `pnpm-corrections` step are removed,
     only with proof:
     - the receipt store list has no `qs@6.16.0` or `undici@8.11.2`;
     - the bundle markers in the receipt dist show the fixed code;
     - the rows fail closed anyway (`test -d` on the old store directory);
   - their `QS_*` and `UNDICI_*` keys leave `versions.env`;
   - `scripts/test-openclaw-base.sh` is wired into `build.yml` (after the image
     build) and `release.yml` (after "Build", before the scan);
   - `SECURITY.md` and the administration docs describe the derivative base.

   The full exact-image qualification then runs on the new Claw candidate.

**Why the image guard is wired at step 4, not earlier:**

- Until the `FROM` lines use a reviewed base digest, the Claw image is built
  from the official image. The guard must refuse that image, because it has
  official OpenClaw layers and the old store entries.
- Wiring it earlier would either break master CI or need a skip mode, and a
  skip mode would be a silent bypass.
- The guard's fixture self-test is wired at step 1, so its code runs on master
  before it guards an image.

## Corrections that stay

- **App npm.** OpenClaw depends on `npm@12.2.0`
  (`/app/node_modules/.pnpm/npm@12.2.0/node_modules/npm`). Its bundled `undici`
  and `ip-address` are inside the npm tarball, which a pnpm override cannot
  reach.
  - The Claw npm step replaces that package in its own layer. On master it
    replaces only the npm package. The #71 branch also replaces the two
    bundled copies and adds `NPM_UNDICI_*` and `NPM_IP_ADDRESS_*`.
  - The image guard requires all three `NPM_*` versions from `versions.env`.
    So it applies only with #71 (step 4).
  - The replaced bytes remain in the base's lower layer. This lower-layer limit
    is the same as on the official base. The merged file system has only the
    corrected copy.
- **Global npm.** The upstream final stage installs `npm@latest` globally, and
  it runs `apt-get dist-upgrade`. Both float.
  - The receipt records what this build got: the global npm version, its
    bundled packages and manifest hash, and the dpkg list.
  - These inputs are not reproducible. A different output is a new digest, and
    it needs new checks.
  - The full final Claw scan, its all-severity report and the bundled-copy
    assessment still apply. A receipt record does not replace them.
- **Pretorin.** The frozen Pretorin binary is outside this graph. Nothing here
  claims that Trivy inspects it.
- **Playwright.** The pre-bundled ip-address copy stays visible as a known
  limit. No override reaches it.

## Limits

- The upstream final stage (apt, npm, corepack) has not run on the hosted
  runner yet. Its time, memory and disk are unmeasured. The r3
  `runtime-assets` build peaked at about 10.5 GB of 16 GB.
- `skopeo` on `ubuntu-24.04` is assumed. The publish job checks for it and
  fails if it is absent.
- The base build is not reproducible byte for byte, because of the floating
  inputs above. `dist` is expected to reproduce for the same inputs, except
  the two stamp files (r3 evidence).
- The image guard proves the composition (manifests, store, layers, version
  surfaces). It does not prove runtime behavior. The existing tests and the
  final qualification do that.
