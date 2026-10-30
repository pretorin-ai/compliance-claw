# How to publish a release

This is a maintainer procedure. For a deployment update, use the
[customer update guide](upgrade.md#routine-deployment-update).
For contribution checks, use [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

Use a reviewed commit on `master`, permission to push tags, GitHub CLI access to
run workflows, and the existing [release workflow](../.github/workflows/release.yml).
Review its current checks and [.trivyignore.yaml](../.trivyignore.yaml) before
publication.

`gh release create` is no longer the trigger. The workflow creates the release
as a draft after its checks, and publishes it only from that draft. Do not
create or publish the release by hand.

The release tag supplies the image version. Do not bump `IMAGE_VERSION` before
the release or invent an image digest. That pin describes what the checkout
deploys, not the next version to publish.

## The release set

Each release has one set of three GitHub Release assets. They bind the source
commit, the version, the immutable image digest, and the deployment files.

| Asset | Content |
| --- | --- |
| `compliance-claw-release.json` | The release record: `stage` (`candidate` or `final`), version, source repository/tag/commit, image repository/digest/reference/platform, the name, role, SHA-256, and size of each other asset, and the signature status. |
| `compose.release.yaml` | A Compose overlay that selects `IMAGE_REPO:X.Y.Z@sha256:…` for `openclaw` and `cli`, plus an `x-compliance-claw-release` metadata field. It has no ports, volumes, environment, or credentials. |
| `sbom-X.Y.Z.spdx.json` | The SPDX software bill of materials (SBOM) of the image. |

[`scripts/release-assets.py`](../scripts/release-assets.py) is the only
program that writes or reads this set. Its header gives the fields, commands,
and exit codes. Guided setup and the updater must use its `fetch` and `check`
commands; they must not parse the record themselves. They are not connected to
it in this version.

The record says `signature.status: unsigned`. The name
`compliance-claw-release.json.sig` is reserved for a later record signature.
Nothing signs the record or the image yet.

**A published set is unsigned today, and customer install and update refuse
it** until signing and signature verification exist: `check` exits 6 unless
`--allow-unsigned` is given. Final trust acceptance is pending. The workflow,
update preview and test fixtures pass `--allow-unsigned`, which admits
`unsigned` only and prints `UNVERIFIED: publisher authenticity not checked`.
Customer install and apply never pass it. Any other status is refused because
this version has no signature verifier.

## Steps

Replace `X.Y.Z` with the intended release version.

1. Tag the reviewed commit and push the tag:

   ```sh
   git tag -a vX.Y.Z -m vX.Y.Z <commit>
   git push origin vX.Y.Z
   ```

2. Prepare the candidate:

   ```sh
   gh workflow run release.yml --ref vX.Y.Z -f operation=prepare
   ```

   The workflow builds `linux/amd64` from the tag, checks the image, the
   file-secret contract, and proxy authentication, scans vulnerabilities, and
   generates the SBOM. Fixable HIGH and CRITICAL findings block publication,
   subject to the reviewed exception file. Scanner failures also fail the run. The
   separate report lists all HIGH and CRITICAL findings; the job summary keeps its
   last 60 lines.

   Then it pushes the image by digest to the `:build` staging reference, pulls
   the digest back, and compares the SBOM of the pulled bytes. Only then does it
   apply `candidate-X.Y.Z` to that digest. It generates the release set and
   attaches it to a **draft** GitHub release `vX.Y.Z`. A draft is not visible to
   customers and sends no release notification. The version tag `X.Y.Z` is not
   applied.

   Prepare refuses when the tag is not at the built commit, when release `vX.Y.Z`
   is already published, or when the image tag `X.Y.Z` already exists. If a
   gate fails before the draft job, the existing draft (if any) does not change.
   A second prepare run for the same version replaces the candidate set on the
   draft. The job summary shows the candidate digest.

3. Qualify the exact candidate. Record its digest from the prepare job summary.
   Use the digest and the assets on the draft. Do not rebuild. To check the draft
   set locally from a checkout of the tag:

   ```sh
   gh release download vX.Y.Z --dir /tmp/cc-vX.Y.Z
   python3 scripts/release-assets.py check --allow-unsigned --dir /tmp/cc-vX.Y.Z \
     --stage candidate --all-assets --version X.Y.Z --source .
   ```

4. Publish the qualified candidate:

   ```sh
   gh workflow run release.yml --ref vX.Y.Z -f operation=publish -f digest=sha256:<qualified digest>
   ```

   Publish does not build. It refuses when the `digest` input is missing or when
   the draft record names another digest, so a later prepare cannot cause
   publication of bytes nobody qualified. It downloads the draft set, checks it
   against the tag and `versions.env`, and changes the record `stage` to `final`. It confirms
   that `candidate-X.Y.Z` still names the recorded digest, and then applies the
   version tag `X.Y.Z` to that digest. It uploads only the final record (the
   overlay and SBOM bytes do not change), compares every published asset with the
   checked set, and then publishes the release.

5. Wait for the full workflow to succeed. Then open one post-release PR that
   changes both values from the job summary:

   - `versions.env`: `IMAGE_VERSION=X.Y.Z`
   - `compose.yaml`: the matching version and published `@sha256:` digest

   The digest exists only after the build. Move the pair together after
   publication. Do not substitute a mutable tag for the digest pin. Before this PR,
   the release overlay is what selects the release image for the tagged source.

Each job has one write permission: GHCR packages or GitHub Release contents,
never both. The workflow uses the automatic `GITHUB_TOKEN`, with no Pretorin,
model, or Slack credentials.

## Retries and failures

- A publish run is safe to repeat with the same `digest`. The record
  finalization is idempotent, the version tag is applied only when it is absent
  or already names the recorded digest, and assets are uploaded only while the
  release is a draft.
- If `final-release` fails after the version tag was applied, re-run the failed
  jobs of that same run (`gh run rerun <run-id> --failed`). That run keeps the
  checked set as an artifact. The record upload replaces the asset, so a failure
  between the delete and the upload can leave the draft without a record; a new
  publish run then stops at "cannot read the release record", and prepare refuses
  because the version tag exists.
- If prepare fails after it moved `candidate-X.Y.Z` but before the draft job, the
  draft and the candidate tag name different digests. Publish then refuses. Run
  prepare again until it succeeds, and qualify the new digest.
- A version tag never moves. A published release is never prepared again and its
  assets are never replaced. To correct a published release, publish a new
  version.
- If prepare stops after the push but before the candidate tag, the workflow
  tries to delete the untagged digest. If the token cannot delete it, delete it
  by hand. A replaced candidate digest keeps no tag; you can delete it by hand.
- Do not update the deployment pin to an unchecked image. If a build, scan,
  digest, or asset check fails, inspect that step and run prepare again.

## Dry run

To rehearse the build, smoke, scan, SBOM, and release-set rules without
publishing:

```sh
gh workflow run release.yml -f operation=dry-run
```

A dry run does not log in, push, tag, or write a release. It does not verify the
registry or release steps. A dry run on a tag labels the image from that tag; on
a branch, from `versions.env`.

## Release notes and discovery

Prepare creates the draft with generated notes. Edit the notes on the draft
before publish. Customers discover a release with native GitHub release
subscriptions: **Watch → Custom → Releases** on the repository. Drafts do not
notify subscribers. There is no other notification service.

## Limits

The image and the release record are not signed. A digest and the asset
checksums give integrity, not authenticity. Publication therefore does not make
a release installable by the customer tools: they refuse it until verification
exists. Signing, a customer-side signature
check, and a required qualification gate that blocks publish are later work;
see the hardening ledger in [SECURITY.md](../SECURITY.md). Do not describe a
release as signed or as verified by a customer signature check.

Publishing an image does not update an existing deployment or its active CLI.
See [update, upgrade and recovery](upgrade.md), [verifying a release](image-verification.md),
and [CLI updates](upgrade.md#updating-the-pretorin-cli).
