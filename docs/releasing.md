# How to publish a release

This is a maintainer procedure. For a deployment update, use the
[customer update guide](upgrade.md#routine-deployment-update).
For contribution checks, use [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

Use a reviewed commit on `master`, permission to push tags, GitHub CLI access to
run workflows, and the existing [release workflow](../.github/workflows/release.yml).
Review its current checks and [.trivyignore.yaml](../.trivyignore.yaml) before
publication.

The tagged commit must contain the reviewed Compliance Claw release key at
[`release-keys/compliance-claw-release.pub`](../release-keys/README.md).
**That key is not committed yet.** Until it is, `finalize` and `publish` refuse,
and no release can be published. You also need access to dispatch the
protected release signer. The signer is maintained separately and never runs
code from this repository.

`gh release create` is no longer the trigger. The workflow creates the release
as a draft after its checks, and publishes it only from that draft. Do not
create or publish the release by hand.

The release tag supplies the image version. Do not bump `IMAGE_VERSION` before
the release or invent an image digest. That pin describes what the checkout
deploys, not the next version to publish.

## The release set

Each release has one set of four GitHub Release assets. They bind the source
commit, the version, the immutable image digest, and the deployment files.

| Asset | Content |
| --- | --- |
| `compliance-claw-release.json` | The release record: `stage` (`candidate` or `final`), version, source repository/tag/commit, image repository/digest/reference/platform, the name, role, SHA-256, and size of each other asset, and the signature fields. |
| `compliance-claw-release.json.sig` | The record signature: one line of base64 of the DER ECDSA P-256 SHA-256 signature over the exact record bytes. The signer adds it to the draft. |
| `compose.release.yaml` | A Compose overlay that selects `IMAGE_REPO:X.Y.Z@sha256:…` for `openclaw` and `cli`, plus an `x-compliance-claw-release` metadata field. It has no ports, volumes, environment, or credentials. |
| `sbom-X.Y.Z.spdx.json` | The SPDX software bill of materials (SBOM) of the image. |

The image signature is not a release asset. It is a cosign signature beside the
digest in the same registry repository (tag `sha256-<hex>.sig`).

[`scripts/release-assets.py`](../scripts/release-assets.py) is the only
program that writes or reads this set. Its header gives the fields, commands,
and exit codes. Guided setup and the updater must use its `fetch` and `check`
commands; they must not parse the record themselves.

A candidate record says `signature.status: unsigned`. `finalize` writes the
final record with `status: signed` and `key_sha256`, the SHA-256 of the DER
public key at the tag, **before** the signer signs it. After that, nothing
rewrites the record. `check` accepts a signed record only when its key is the
key of the checkout and both signatures verify with that key. A `signed` status
alone proves nothing. `--allow-unsigned` admits only `unsigned`, for the
candidate checks, update preview and test fixtures. Customer install and apply
never pass it.

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
   A second prepare run for the same version deletes an earlier record
   signature from the draft, then replaces the candidate set. The job summary
   shows the candidate digest.

3. Check the exact candidate. Record its digest from the prepare job summary.
   Use the digest and the assets on the draft. Do not rebuild. To check the draft
   set locally from a checkout of the tag:

   ```sh
   gh release download vX.Y.Z --dir /tmp/cc-vX.Y.Z
   python3 scripts/release-assets.py check --allow-unsigned --dir /tmp/cc-vX.Y.Z \
     --stage candidate --all-assets --version X.Y.Z --source .
   ```

4. Write the final record on the draft:

   ```sh
   gh workflow run release.yml --ref vX.Y.Z -f operation=finalize -f digest=sha256:<prepared candidate digest>
   ```

   Finalize does not build and applies no version tag. The release stays a
   draft. It refuses when the `digest` input is missing, when the draft record
   names another digest, when `candidate-X.Y.Z` names another digest, when the
   checkout is not the tag commit, or when the tag has no trust key. It replaces
   only the record on the draft, then reads it back. The log and the job
   summary say **NOT PUBLISHED — awaiting signatures**, with the record SHA-256
   and the key fingerprint.

5. Dispatch the protected release signer for tag `vX.Y.Z` and the same digest.
   It checks the draft set, signs the exact final record and the image digest
   with the release key, uploads `compliance-claw-release.json.sig` to the
   draft, and pushes the image signature beside the digest.

6. Publish:

   ```sh
   gh workflow run release.yml --ref vX.Y.Z -f operation=publish -f digest=sha256:<prepared candidate digest>
   ```

   Publish does not build and never rewrites the record. It downloads the four
   draft assets and checks them against the tag, `versions.env` and the
   `digest` input. It verifies the record signature with the key at the tag.
   It confirms that `candidate-X.Y.Z` still names the recorded digest, and
   verifies the image signature at that digest with the same key. Only then
   does it apply the version tag `X.Y.Z` to that digest. Then it compares every
   draft asset with the verified set, byte for byte, and publishes the release.
   A missing, altered, stale, or wrong-key signature stops publish before the
   version tag, and the release stays a draft.

   After publication, the workflow downloads the set from the public release
   URLs without a token and verifies it. It also reports whether the image can
   be pulled without a login. The package is not public today, so the report
   says `login-required`.

7. Wait for the full workflow to succeed. Then open one post-release PR that
   changes both values from the job summary:

   - `versions.env`: `IMAGE_VERSION=X.Y.Z`
   - `compose.yaml`: the matching version and published `@sha256:` digest

   The digest exists only after the build. Move the pair together after
   publication. Do not substitute a mutable tag for the digest pin. Before this PR,
   the release overlay is what selects the release image for the tagged source.

Each job has one write permission: GHCR packages or GitHub Release contents,
never both. The workflow uses the automatic `GITHUB_TOKEN`, with no Pretorin,
model, or Slack credentials, and no signing key.

The prepare, finalize and publish jobs use the protected `release`
environment: each job waits for a required reviewer. One release needs six
approvals: two for prepare (`candidate`, `draft`), one for finalize
(`final-record`) and three for publish (`final-assets`, `final-image`,
`final-release`). A dry run uses no environment.

## Retries and failures

- Publish writes no asset. It is safe to repeat with the same `digest`: the
  version tag is applied only when it is absent or already names the recorded
  digest, and un-draft is the last write.
- Finalize changes nothing when the draft already holds the same final record.
  A finalize that fails before its upload changes nothing; run it again.
- **Finalize upload failure.** `gh release upload --clobber` deletes the old
  asset before it uploads the new one. If the upload fails, the draft can have
  **no record**, and a new finalize run cannot download one. Before the upload,
  the run keeps the final record as the artifact
  `final-record-X.Y.Z-attempt-N`, and its error names the commands. From a
  checkout of the tag:

  ```sh
  gh run download <run-id> --repo pretorin-ai/compliance-claw --name final-record-X.Y.Z-attempt-N --dir /tmp/cc-final
  gh release download vX.Y.Z --repo pretorin-ai/compliance-claw --dir /tmp/cc-final \
    --pattern compose.release.yaml --pattern sbom-X.Y.Z.spdx.json
  python3 scripts/release-assets.py finalize --dir /tmp/cc-final --source .   # must say "already"
  gh release upload vX.Y.Z --repo pretorin-ai/compliance-claw /tmp/cc-final/compliance-claw-release.json
  gh workflow run release.yml --ref vX.Y.Z -f operation=finalize -f digest=sha256:<digest>
  ```

  The upload has no `--clobber`, so it cannot replace a record that is there.
  The second finalize reads the record back and writes nothing. If the artifact
  is not available, run prepare again on the tag (see below). A new build has a
  new candidate digest, which needs a new exact-digest check before finalize.
- A second prepare uses `--clobber` too. If its upload fails, run prepare again.
- If publish stops at a signature check, do not edit the record or the
  signature. Find the cause (signer not run, other key, stale signature), fix
  it at the signer, then run publish again.
- A new candidate invalidates every earlier signature. A second prepare on a
  draft deletes the `.sig` asset first, then replaces the set. Run finalize and
  the signer again. Finalize also refuses a `.sig` beside a candidate record;
  if one is there, delete it from the draft by hand. An earlier image signature
  names only the earlier digest, which no record names any more.
- If `final-release` fails after the version tag was applied, re-run the failed
  jobs of that same run (`gh run rerun <run-id> --failed`), or run publish again.
- If prepare fails after it moved `candidate-X.Y.Z` but before the draft job, the
  draft and the candidate tag name different digests. Finalize and publish then
  refuse. Run prepare again until it succeeds, and check the new digest.
- A version tag never moves. A published release is never prepared again and its
  assets are never replaced. To correct a published release, publish a new
  version.
- If prepare stops after the push but before the candidate tag, the workflow
  tries to delete the untagged digest. If the token cannot delete it, delete it
  by hand. A replaced candidate digest keeps no tag; you can delete it by hand.
  The cleanup selects only the pushed image digest that carries no tag except
  `build`. A signature is a separate package version, so the cleanup never
  selects it. Do not delete `sha256-<hex>.sig` versions by hand: customers
  need them.
- Do not update the deployment pin to an unchecked image. If a build, scan,
  digest, or asset check fails, inspect that step and run prepare again.

## Dry run

To rehearse the build, smoke, scan, SBOM, and release-set rules without
publishing:

```sh
gh workflow run release.yml -f operation=dry-run
```

A dry run does not log in, push, tag, or write a release. It does not verify the
registry, signature or release steps. A dry run on a tag labels the image from
that tag; on a branch, from `versions.env`.

## Release notes and discovery

Prepare creates the draft with generated notes. The notes start with a
statement that install and update verify the record and image signatures with
the release key from the checkout. Edit the notes on the draft before publish,
but keep that statement. Customers discover a release with native GitHub
release subscriptions: **Watch → Custom → Releases** on the repository. Drafts
do not notify subscribers. There is no other notification service.

## Limits

The signatures prove that the release key signed this record and this digest.
They do not prove that the release key itself is the right key: that depends on
the reviewed key in the checkout and the
[first-trust fingerprint comparison](image-verification.md#first-trust-in-the-release-key).
There is no transparency log. A release published before signing (v0.5.3 and
earlier) stays unsigned, and install and update refuse it. The verifier in those
checkouts refuses every signed release, so a deployment on v0.5.3 or earlier
moves to the first signed release by the manual path in
[upgrade.md](upgrade.md#moving-from-an-unsigned-release).

Publishing an image does not update an existing deployment or its active CLI.
See [update, upgrade and recovery](upgrade.md), [verifying a release](image-verification.md),
and [CLI updates](upgrade.md#updating-the-pretorin-cli).
