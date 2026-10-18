# How to publish a release

This is a maintainer procedure. For a deployment update, use the
[customer update guide](../README.md#updating-an-existing-deployment).
For contribution checks, use [CONTRIBUTING.md](../CONTRIBUTING.md).

## Prerequisites

Use a reviewed commit on `master`, GitHub CLI access to create releases, and the
existing [release workflow](../.github/workflows/release.yml). Review its current
checks and [.trivyignore.yaml](../.trivyignore.yaml) before publication.

The release tag supplies the image version. Do not bump `IMAGE_VERSION` before
the release or invent an image digest. That pin describes what the checkout
deploys, not the next version to publish.

## Steps

Replace `X.Y.Z` with the intended release version:

```sh
gh release create vX.Y.Z --target master --generate-notes
```

The `release: published` event starts the workflow. It builds `linux/amd64`,
checks the image and file-secret contract, scans vulnerabilities, and generates
an SPDX software bill of materials (SBOM). Fixable CRITICAL findings block
publication, subject to the reviewed exception file. HIGH and unfixed findings
are reported separately.

The workflow pushes a staging reference, pulls its digest back, checks the
pulled bytes and SBOM, and only then applies and verifies the version tag.
It also uploads the SBOM to the GitHub Release. The image and SBOM are not signed.
The workflow uses the automatic `GITHUB_TOKEN`, with no Pretorin, model, or Slack
credentials.

Wait for the full workflow to succeed. Then open one post-release PR that changes
both values from the job summary:

- `versions.env`: `IMAGE_VERSION=X.Y.Z`
- `compose.yaml`: the matching version and published `@sha256:` digest

The digest exists only after the build. Move the pair together after publication.
Do not substitute a mutable tag for the digest pin.

## Verification and troubleshooting

Check the workflow result, image digest/tag result, release SBOM asset, and job
summary before the pin PR. If a build, scan, or digest check fails, inspect that
step; do not update the deployment pin to an unchecked image. Package cleanup,
image signing, and release automation changes are separate work.

To rehearse build, scan, and SBOM checks without publishing:

```sh
gh workflow run release.yml -f dry_run=true
```

A dry run does not verify the registry push/tag steps. Publishing an image does
not update an existing deployment or its active CLI. See
[upgrade and recovery](upgrade.md) and [CLI updates](../README.md#updating-the-pretorin-cli).
