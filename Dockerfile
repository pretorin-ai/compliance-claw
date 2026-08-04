# compliance-claw — OpenClaw + Pretorin CLI, local linux/amd64 deployment.
#
# Two stages: `pretorin-verify` produces a supply-chain-verified Pretorin binary
# at /usr/local/bin/pretorin, and the final runtime stage joins it to OpenClaw.
#
# Build (amd64 is the deployment target; upstream ships no linux/arm64 binary):
#   docker build --platform linux/amd64 -t compliance-claw:local .
#   docker build --platform linux/amd64 --target pretorin-verify -t cc-verify .
#
# No --build-arg needed, and no credentials are involved because the release
# source is a public repository.
#
# Pin carve-out: every pin lives in versions.env EXCEPT the image digests on the
# FROM lines below, because FROM cannot read a sourced file. Those are the only
# pins to bump here rather than there; versions.env says the same.
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


# Runtime: OpenClaw, with the verified Pretorin binary and its skill added.
#
# The digest is the OCI index, not the amd64 manifest — same as the debian pin
# above. An index digest still resolves per-platform, so the multi-arch work
# later needs no change here, and `--platform` keeps meaning what it says.
#
# The base is node:24-bookworm-slim underneath, i.e. glibc: what the dynamically
# linked Pretorin binary needs. An Alpine-based OpenClaw image would not run it.
FROM ghcr.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c

# The image already runs as `node`; switch back at the end of the stage.
USER root

COPY --from=pretorin-verify /usr/local/bin/pretorin /usr/local/bin/

# --path, not --agent: the built-in agent registry knows only claude and codex
# and roots both under /root, which this image's non-root user cannot read.
# Installing to an explicit directory instead keeps the skill outside both the
# state volume and the read-only target mount, so neither can shadow or hide it.
# Making OpenClaw actually load this directory is Phase 3 (skills.load.extraDirs).
RUN install -d /opt/compliance-claw/skills \
 && pretorin skill install --path /opt/compliance-claw/skills \
 && chown -R node:node /opt/compliance-claw

# /home/node/.openclaw already exists in the base image, owned by node — a fresh
# named volume is seeded from it, so the state mount needs no ownership fixup.
# The target mount point is created here rather than left to the daemon, which
# would create a missing mount point as root and leave it unreadable.
RUN install -d -o node -g node /workspace/targets

# Config is generated on first start, not baked: ~/.openclaw is a named volume,
# so anything baked there would be shadowed on first start. These are the
# templates the entrypoint installs from.
COPY scripts/openclaw-config.template.json scripts/agents-md.template /opt/compliance-claw/
COPY scripts/entrypoint.sh /usr/local/bin/compliance-claw-entrypoint

# versions.env is the single source of truth for MODEL, and neither ENV nor FROM
# can read a sourced file — so the substitution happens here, at build time. The
# shipped template is therefore concrete and inspectable, and an unset MODEL
# fails the build instead of producing a config with a placeholder model.
#
# The tini assertion is not ceremony: the entrypoint execs this exact path to
# stay PID 1, and an OpenClaw base image that ever moves or drops tini should
# break the build rather than every deployment.
COPY versions.env /opt/compliance-claw/versions.env
RUN . /opt/compliance-claw/versions.env \
 && test -n "${MODEL}" \
 && sed -i "s|@MODEL@|${MODEL}|" /opt/compliance-claw/openclaw-config.template.json \
 && ! grep -q '@MODEL@' /opt/compliance-claw/openclaw-config.template.json \
 && test -x /usr/bin/tini \
 && chmod 0755 /usr/local/bin/compliance-claw-entrypoint \
 && chown -R node:node /opt/compliance-claw

USER node

# The wrapper seeds config, then execs the base image's own `tini -s --`, so
# tini is still PID 1 and still passes arguments through — `docker compose run
# --rm cli pretorin version` runs exactly that, and gets the seeded config too.
#
# CMD must be RESTATED, not inherited: Docker resets an inherited CMD to null
# whenever a stage sets ENTRYPOINT. Omitting it hands tini zero arguments, and
# tini answers by printing its usage and exiting 1 — found by the Phase 3 gate,
# not by reading the docs. WorkingDir stays the inherited /app, which is where
# openclaw.mjs lives.
ENTRYPOINT ["/usr/local/bin/compliance-claw-entrypoint"]
CMD ["node", "openclaw.mjs", "gateway"]
