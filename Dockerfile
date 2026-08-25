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


# The OpenClaw Slack channel plugin, resolved and integrity-checked at BUILD
# time. Slack is NOT bundled in 2026.7.1 — `openclaw plugins list` reports 70
# stock plugins and slack is not one of them — so it comes from npm.
#
# Why a build stage instead of `openclaw plugins install`: that command writes to
# $OPENCLAW_STATE_DIR/npm/projects/..., i.e. INSIDE the ~/.openclaw named volume.
# A managed install is therefore destroyed by `docker compose down -v` and can
# never be pinned in an image. Installing here and pointing plugins.load.paths at
# the image copy makes the plugin part of the image, like the Pretorin binary.
#
# This stage uses the OpenClaw image because it already carries the exact node
# and npm the runtime will load the plugin with (node 24 / npm 11), so the
# resolved tree is the tree that actually runs.
FROM ghcr.io/openclaw/openclaw:2026.7.1@sha256:6a31d44b2944e7adcd2b582bf6fb463111264ebca97a0201795b799135bd102c AS slack-plugin

USER root
WORKDIR /build

COPY versions.env ./

# The gate: npm's own resolution is never trusted. The integrity recorded in the
# generated package-lock.json is compared against the PINNED value in
# versions.env, exactly as verify-pretorin.sh compares the binary against
# PRETORIN_SHA256. A registry that serves different bytes under the same version
# fails the build instead of shipping.
#
# No lock file is vendored here because the published package ships its own
# npm-shrinkwrap.json, which pins all 103 transitive dependencies. That is also
# why the tree ends up NESTED under the plugin directory rather than hoisted to
# /build/node_modules, which is what makes copying just the plugin directory
# self-contained.
RUN . ./versions.env \
 && test -n "${SLACK_PLUGIN_VERSION}" \
 && test -n "${SLACK_PLUGIN_INTEGRITY}" \
 && npm install --no-audit --no-fund --loglevel=error \
      "@openclaw/slack@${SLACK_PLUGIN_VERSION}" \
 && RESOLVED="$(node -e 'const e=require("/build/package-lock.json").packages["node_modules/@openclaw/slack"]; if(!e||!e.integrity){console.error("no package-lock entry for @openclaw/slack");process.exit(1)} process.stdout.write(e.integrity)')" \
 && if [ "$RESOLVED" != "${SLACK_PLUGIN_INTEGRITY}" ]; then \
      echo "SLACK PLUGIN INTEGRITY MISMATCH" >&2; \
      echo "  pinned:   ${SLACK_PLUGIN_INTEGRITY}" >&2; \
      echo "  resolved: ${RESOLVED}" >&2; \
      echo "  Refusing to build. Re-derive the pin only after auditing the change:" >&2; \
      echo "    npm view @openclaw/slack@${SLACK_PLUGIN_VERSION} dist.integrity" >&2; \
      exit 1; \
    fi \
 && echo "SLACK PLUGIN VERIFIED: ${SLACK_PLUGIN_VERSION} ${RESOLVED}"

# Structural assertions on what is about to be copied. Deliberately NOT
# `import()` of dist/index.js: the plugin imports the host package `openclaw`,
# which only resolves inside the gateway's own module graph, so a bare node
# import always fails with "Cannot find package 'openclaw'" even on a perfectly
# good install. What is checkable here is that the manifest says slack, the entry
# point exists, and the nested dependency tree resolves. Proof that OpenClaw
# actually LOADS it belongs to scripts/smoke.sh, which asserts
# `openclaw plugins inspect slack` reports Status: loaded.
RUN P=/build/node_modules/@openclaw/slack \
 && test -f "$P/openclaw.plugin.json" \
 && test "$(node -e 'process.stdout.write(require("/build/node_modules/@openclaw/slack/openclaw.plugin.json").id)')" = slack \
 && test -f "$P/dist/index.js" \
 && node -e 'require.resolve("@slack/bolt",{paths:["/build/node_modules/@openclaw/slack"]})' \
 && node -e 'require.resolve("@slack/socket-mode",{paths:["/build/node_modules/@openclaw/slack"]})' \
 && echo "slack plugin tree resolves"


# Runtime: OpenClaw, with the verified Pretorin binary added as an immutable seed.
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

# THE SEED, AND WHY IT IS NOT ON PATH.
#
# This is the verified binary, and it is a seed: the entrypoint copies it once
# into the pretorin-state volume and everything afterwards runs the copy. Keeping
# it off PATH is what makes `pretorin` mean exactly one thing. If a seed sat at
# /usr/local/bin/pretorin, then `docker compose run --rm cli pretorin version`
# would answer with the image's version while MCP ran a different, updated
# binary — two correct answers to one question, which is how an operator ends up
# debugging the wrong file.
#
# Anything that deliberately wants the seed names this path explicitly:
# .github/workflows/release.yml probes the image with `--entrypoint bash`, which
# skips seeding, so it has no active binary to ask.
COPY --from=pretorin-verify --chown=root:root \
     /usr/local/bin/pretorin /opt/compliance-claw/pretorin-seed/pretorin

# The active CLI lives in the pretorin-state volume and is first on PATH, so MCP,
# onboarding, smoke and every operator command resolve the same binary. The
# directory is created (node-owned) below; until the entrypoint seeds it, it is
# empty, which is why every image-level probe names the seed instead.
ENV PATH="/home/node/.pretorin/bin:${PATH}"

# The OpenAI request adapter, as an IMAGE-LEVEL DEFAULT.
#
# The config template carries ${OPENAI_REQUEST_ADAPTER} and the entrypoint exports
# the right value for the process it is about to exec. But `docker compose exec`
# does not go through the entrypoint, so an exec'd `openclaw ...` would see the
# variable unset — and an unset ${VAR} does not fall back to anything, it makes the
# WHOLE CONFIG INVALID. That broke `docker compose exec openclaw openclaw agent`,
# which README documents as the way to run a turn.
#
# So the image declares the device-login value here, which makes the config parse
# for any process in the container, and the entrypoint overrides it to
# openai-responses for PID 1 when an OpenAI key is actually present.
#
# Safe for exec'd clients specifically because `openclaw agent` talks to the
# GATEWAY over loopback: inference happens in PID 1, which has the correct value.
# The exec'd process only needs the config to parse.
ENV OPENAI_REQUEST_ADAPTER="openai-chatgpt-responses"

# /home/node/.openclaw already exists in the base image, owned by node — a fresh
# named volume is seeded from it, so the state mount needs no ownership fixup.
# The target mount point is created here rather than left to the daemon, which
# would create a missing mount point as root and leave it unreadable.
#
# /home/node/.pretorin gets the same treatment for the same reason, and it is
# NOT optional: Pretorin keeps its active context, preflight resolvers and
# active recipe set there, outside ~/.openclaw, so compose mounts a second named
# volume over it. Without this line the daemon creates that mount point as root
# and onboarding fails with a permission error on the first write.
RUN install -d -o node -g node /workspace/targets \
 && install -d -m 0700 -o node -g node /home/node/.pretorin \
 && install -d -m 0700 -o node -g node /home/node/.pretorin/bin

# The working directory for the `pretorin mcp-serve` child, referenced as
# mcp.servers.pretorin.cwd in the config template. A sentinel, not a workspace:
# no .git, no .md, no code, so Pretorin's CWD-based host discovery finds nothing
# plausible here. Without it the child inherits /app and can register the
# OpenClaw install tree as the repository under review. The notice is .txt on
# purpose — the document_repository default marker is **/*.md.
RUN install -d -o node -g node /opt/compliance-claw/no-repo \
 && printf '%s\n' \
      'This directory is intentionally empty.' \
      '' \
      'It is the working directory of the `pretorin mcp-serve` child process' \
      '(mcp.servers.pretorin.cwd in ~/.openclaw/openclaw.json). Pretorin can' \
      'derive host-local source resolvers from the current directory, so that' \
      'directory must contain nothing that looks like a repository or a document' \
      'set. Do not add files here, and do not point it at a real repository.' \
      '' \
      'Repositories under review are declared in targets.yaml, bind-mounted' \
      'read-only at /workspace/targets, and bound explicitly by' \
      'scripts/onboard-targets.sh.' \
      > /opt/compliance-claw/no-repo/README-DO-NOT-ADD-FILES.txt \
 && chown node:node /opt/compliance-claw/no-repo/README-DO-NOT-ADD-FILES.txt

# The verified Slack plugin, outside the state volume so `down -v` cannot remove
# it and a newer image always ships the pinned version. Just the package
# directory: its dependency tree is nested inside it (the published package
# carries npm-shrinkwrap.json), so nothing else from /build is needed.
#
# node-owned because OpenClaw refuses to load plugin files owned by a different
# uid than the process — "blocked plugin candidate: suspicious ownership". The
# runtime is uid 1000 (node), so this must be too.
#
# Referenced as plugins.load.paths in scripts/slack-channel.patch.json5.
COPY --from=slack-plugin --chown=node:node \
     /build/node_modules/@openclaw/slack /opt/compliance-claw/plugins/slack

# Config is generated on first start, not baked: ~/.openclaw is a named volume,
# so anything baked there would be shadowed on first start. These are the
# templates the entrypoint installs from. The Slack fragment is a separate patch
# rather than part of the base template because Slack is optional: the entrypoint
# applies it with `openclaw config patch` only on a fresh seed and only when the
# operator supplied all three Slack variables.
COPY scripts/openclaw-config.template.json scripts/agents-md.template \
     scripts/slack-channel.patch.json5 /opt/compliance-claw/
COPY scripts/entrypoint.sh /usr/local/bin/compliance-claw-entrypoint

# The CLI updater. One implementation; the Slack plugin, the model-visible tool
# and scripts/pretorin-update.sh on the host all call this same file, so the
# locking, backup, verification, rollback, sanitized environment and audit logic
# exist once.
COPY scripts/pretorin-update.in-image.sh /opt/compliance-claw/pretorin-update.sh

# The updater plugin: one command (/pretorin-update, which bypasses the LLM) and
# one narrowly typed agent tool, both calling the wrapper above.
#
# Plain COPY, never --link: OpenClaw rejects a plugin candidate whose files are
# hardlinked (nlink > 1) for any non-bundled origin, and --link produces exactly
# that. node-owned for the same reason as the Slack plugin above.
COPY --chown=node:node plugins/pretorin-update /opt/compliance-claw/plugins/pretorin-update

# The MCP stdio client used by scripts/smoke.sh to prove key posture — a read
# tool succeeds, a write tool is rejected server-side — through the same
# transport the agent uses. In the image rather than on the host because it
# speaks to `pretorin mcp-serve`, which lives here.
COPY scripts/mcp-call.py /opt/compliance-claw/

# versions.env is the single source of truth for MODEL, and neither ENV nor FROM
# can read a sourced file — so the substitution happens here, at build time. The
# shipped template is therefore concrete and inspectable, and an unset MODEL
# fails the build instead of producing a config with a placeholder model.
#
# The tini assertion is not ceremony: the entrypoint execs this exact path to
# stay PID 1, and an OpenClaw base image that ever moves or drops tini should
# break the build rather than every deployment.
#
# CONFIG_TEMPLATE_VERSION lands in a file next to the templates for the same
# reason: the entrypoint reads it to detect a state volume whose config predates
# this image, and it must come from the one place versions are declared.
# WHAT VERSION THIS IMAGE IS, decided by whoever builds it — because the image
# cannot know. versions.env's IMAGE_VERSION describes what a CHECKOUT DEPLOYS,
# and the commit that moves it lands AFTER the release is published. Baking that
# line unchanged is how the v0.2.0 image ended up self-reporting 0.1.0.
#
# So the release passes the version derived from the GIT TAG, which is the single
# source of truth at release time, and it is recorded in two places an operator
# might look: the OCI label, and the copy of versions.env inside the image.
#
# The default is deliberately NOT a release number. An unlabelled local build
# must never impersonate a release, so it says 0.0.0-dev and means it;
# scripts/bootstrap.sh --build refines that to 0.0.0-dev+<shortsha>.
#
# This is an ARG rather than something computed in the RUN below because a LABEL
# can only reference a build argument — a value derived inside a shell is not
# visible to it.
ARG IMAGE_SELF_VERSION=0.0.0-dev
LABEL org.opencontainers.image.version="${IMAGE_SELF_VERSION}"

COPY versions.env /opt/compliance-claw/versions.env
RUN . /opt/compliance-claw/versions.env \
 && test -n "${MODEL}" \
 && sed -i "s|@MODEL@|${MODEL}|" /opt/compliance-claw/openclaw-config.template.json \
 && ! grep -q '@MODEL@' /opt/compliance-claw/openclaw-config.template.json \
 && test -n "${CONFIG_TEMPLATE_VERSION}" \
 && printf '%s\n' "${CONFIG_TEMPLATE_VERSION}" > /opt/compliance-claw/config-template.version \
 && test -n "${IMAGE_SELF_VERSION}" \
 && sed -i "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${IMAGE_SELF_VERSION}|" \
      /opt/compliance-claw/versions.env \
 && grep -qx "IMAGE_VERSION=${IMAGE_SELF_VERSION}" /opt/compliance-claw/versions.env \
 && test -x /usr/bin/tini \
 && chmod 0755 /usr/local/bin/compliance-claw-entrypoint \
 && chown -R node:node /opt/compliance-claw \
 && chown -R root:root /opt/compliance-claw/pretorin-seed \
 && chmod 0755 /opt/compliance-claw/pretorin-seed/pretorin \
 && chmod 0755 /opt/compliance-claw/pretorin-update.sh

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
