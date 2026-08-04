# compliance-claw — OpenClaw + Pretorin CLI, local linux/amd64 deployment.
#
# Phase 1 provides the `pretorin-verify` stage only: it produces a
# supply-chain-verified Pretorin binary at /usr/local/bin/pretorin. Later phases
# add stages alongside it and consume the result with:
#
#   COPY --from=pretorin-verify /usr/local/bin/pretorin /usr/local/bin/
#
# Build (amd64 is the deployment target; upstream ships no linux/arm64 binary):
#   docker build --platform linux/amd64 --target pretorin-verify -t cc-verify .
#
# No --build-arg needed, and no credentials are involved because the release
# source is a public repository.
#
# Pin carve-out: every pin lives in versions.env EXCEPT the base image digest on
# the FROM line below, because FROM cannot read a sourced file. That is the one
# pin to bump here rather than there; versions.env says the same.
#
# Note: intentionally no `# syntax=` directive — nothing here needs a BuildKit
# frontend, and requiring one adds a network pull that can fail the build.
# --platform belongs on the build command, not on FROM (which trips
# FromPlatformFlagConstDisallowed and hardcodes the arch into the file).
FROM debian:trixie-slim@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd AS pretorin-verify

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/compliance-claw

COPY versions.env ./

# Pinned, checksum-verified cosign — the tool that does the verifying is itself
# verified. The bytes are compared against the PINNED digest in versions.env and
# never against a checksum file downloaded alongside them, and they are only made
# executable after that comparison passes.
RUN . ./versions.env \
 && curl -fsSL --retry 3 --retry-all-errors -o /tmp/cosign \
      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/${COSIGN_ASSET}" \
 && echo "${COSIGN_SHA256}  /tmp/cosign" | sha256sum -c - \
 && install -m 0755 /tmp/cosign /usr/local/bin/cosign \
 && rm /tmp/cosign \
 && cosign version

COPY vendor/ vendor/
COPY scripts/ scripts/

# Fetch is untrusted byte movement; verify is where every trust decision happens.
# dist/ is removed so the unverified downloads never persist into a layer that
# later stages could accidentally copy from.
#
# Invoked via `bash` rather than directly: COPY preserves whatever mode the file
# had in the build context, so a script committed without its exec bit (e.g. from
# a checkout with core.fileMode=false) would fail here with a bare
# "permission denied" on a file that is plainly present.
RUN bash scripts/fetch-pretorin.sh dist \
 && bash scripts/verify-pretorin.sh dist \
 && rm -rf dist
