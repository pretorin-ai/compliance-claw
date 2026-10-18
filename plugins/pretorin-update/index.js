/**
 * Pretorin CLI updater — one command, one tool, one implementation.
 *
 * Both routes shell out to the SAME in-image wrapper, so the locking, backup,
 * signature verification, rollback, sanitized environment and audit trail live
 * in exactly one place (scripts/pretorin-update.in-image.sh):
 *
 *   /pretorin-update <latest|X.Y.Z>   a command, which BYPASSES THE LLM. Core
 *                                     enforces authorization before the handler
 *                                     runs, and no agent tool can invoke it, so
 *                                     a prompt-injected agent cannot reach it.
 *
 *   pretorin_update                   a model-visible tool, deliberately
 *                                     prompt-injectable in this trusted-repo
 *                                     pilot. Its blast radius is bounded to
 *                                     WHICH SIGNED VERSION installs: no command,
 *                                     path or URL is expressible.
 *
 * This is plain ESM with zero imports from the host. `definePluginEntry` is a
 * plain-object factory and the loader accepts any object exposing `register`, so
 * the image needs no Node toolchain and no npm dependency to carry this.
 */
import { spawn } from "node:child_process";
import { createActivation, MANUAL_RESTART } from "./activation.js";

const WRAPPER = "/opt/compliance-claw/pretorin-update.sh";
const TIMEOUT_MS = 360_000;

/**
 * Run the wrapper. Identity is passed through the ENVIRONMENT, never as an
 * argument: an argument is something a model could write, and the audit record
 * has to mean something. The wrapper re-execs itself under `env -i` and keeps
 * only these two non-secret variables.
 */
function runWrapper(arg, { requester, route }) {
  return new Promise((resolve) => {
    const args = arg === undefined || arg === null || arg === "" ? [] : [String(arg)];
    let child;
    try {
      child = spawn(WRAPPER, args, {
        // stderr is INHERITED on purpose. The wrapper writes its audit line to
        // both a file in the volume and stderr; inheriting is what puts the
        // stderr copy into `docker compose logs`, outside the volume the agent
        // can write to. `stdio: "ignore"` would silently throw that away.
        stdio: ["ignore", "pipe", "inherit"],
        env: {
          PATH: "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
          HOME: "/home/node",
          PRETORIN_UPDATE_REQUESTER: requester || "unavailable",
          PRETORIN_UPDATE_ROUTE: route || "unknown",
        },
      });
    } catch (err) {
      resolve({ ok: false, code: -1, stdout: "", error: String(err?.message ?? err) });
      return;
    }

    let stdout = "";
    child.stdout?.on("data", (d) => { stdout += String(d); });

    const timer = setTimeout(() => {
      try { child.kill("SIGKILL"); } catch { /* already gone */ }
    }, TIMEOUT_MS);

    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ ok: false, code: -1, stdout, error: String(err?.message ?? err) });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ ok: code === 0, code, stdout });
    });
  });
}

function resultingVersion(stdout) {
  const m = /^ACTIVE_VERSION=(.+)$/m.exec(stdout || "");
  return m ? m[1].trim() : null;
}

const SHARED_INSTANCE_NOTE =
  "This changes the Pretorin CLI for EVERY user of this instance. " +
  "An owner can request a safe restart. Wait for the final activation message before treating the update as complete.";

/** Shared by both routes so they cannot drift in what they promise. */
async function performUpdate({ arg, requester, route, activation, ctx }) {
  const res = await runWrapper(arg, { requester, route });

  if (!res.ok) {
    const detail = res.error ? ` (${res.error})` : ` (exit ${res.code})`;
    return (
      `Pretorin CLI installation FAILED${detail}.\n` +
      "Activation was not verified. See `docker compose logs openclaw` for the audit line, " +
      "or run `scripts/pretorin-update.sh --status`."
    );
  }

  const version = resultingVersion(res.stdout);
  if (!version) {
    return (
      "Pretorin CLI installation could not be verified: no resulting version could be read. " +
      "Treating that as a failure; run `scripts/pretorin-update.sh --status` to check."
    );
  }

  if (route === "command") {
    try {
      if (await activation.request(version, ctx)) {
        return `Pretorin CLI ${version} installation succeeded. Gateway restart requested. Activation is unverified. A final Slack message will confirm activation or report the required operator action.`;
      }
    } catch { /* Installation succeeded; use the verified operator fallback. */ }
  }
  return `Pretorin CLI ${version} installation succeeded. OPERATOR RESTART REQUIRED. ${MANUAL_RESTART}`;
}

export default {
  id: "pretorin-update",
  name: "Pretorin CLI Updater",
  description: "Update this deployment's Pretorin CLI in place.",

  // MUST be synchronous. The loader rejects a promise-returning register with
  // "plugin register must be synchronous".
  register(api) {
    const activation = createActivation(api);
    api.on?.("gateway_start", activation.resume);
    let updating = false;
    api.registerCommand({
      name: "pretorin-update",
      description: "Update this deployment's Pretorin CLI (latest, or an explicit X.Y.Z).",
      // Without acceptsArgs the command silently does not match once an
      // argument is present, and the message falls through to the agent.
      acceptsArgs: true,
      // Core rejects unauthorized senders before this handler ever runs.
      requireAuth: true,
      requiredScopes: ["operator.admin"],
      agentPromptGuidance: [
        {
          text:
            "Pretorin CLI updates are available. `/pretorin-update latest` and " +
            "`/pretorin-update X.Y.Z` are operator commands that bypass the model; the " +
            "pretorin_update tool does the same thing conversationally. Never claim an " +
            "installation succeeded unless the tool returned an installed version. " +
            "Activation remains unverified until the final activation result. The model tool requires an operator restart; do not claim the update is complete from installation alone.",
          surfaces: ["openclaw_main"],
        },
      ],
      handler: async (ctx) => {
        const arg = (ctx.args ?? "").trim();

        if (arg === "status" || arg === "--status") {
          const res = await runWrapper("--status", {
            requester: ctx.senderId,
            route: "command",
          });
          return { text: "```\n" + (res.stdout || "(no output)").trim() + "\n```" };
        }

        if (arg === "") {
          return {
            text:
              "Usage: `/pretorin-update latest` | `/pretorin-update X.Y.Z` | `/pretorin-update status`\n" +
              SHARED_INSTANCE_NOTE,
          };
        }

        // Identity comes from the authenticated inbound message, which core
        // populated and gated. It is never taken from the argument.
        const requester = `${ctx.channel ?? "unknown"}:${ctx.senderId ?? "unavailable"}`;
        // Slack acknowledges before dispatch. Keep this invocation open so core
        // delivers the final result. The command execution counter permits
        // concurrent commands, including status; it only drains on retirement.
        if (updating || activation.hasPending()) return { text: "A Pretorin update is pending. Wait for its activation result. Use `/pretorin-update status` to check the installed file." };
        updating = true;
        try {
          return { text: await performUpdate({ arg, requester, route: "command", activation, ctx }) };
        } finally { updating = false; }
      },
    });

    // FACTORY FORM IS MANDATORY for the tool route. The per-call execute context
    // is only { api, signal, toolCallId, onUpdate } — it carries no identity at
    // all. Trusted identity lives on the factory's context as requesterSenderId,
    // which the host populates from the inbound envelope, so the only way to
    // record who asked is to close over it here.
    api.registerTool(
      (toolContext) => ({
        name: "pretorin_update",
        label: "Update Pretorin CLI",
        description:
          "Update this deployment's Pretorin CLI. Accepts 'latest' for the latest stable " +
          "release, or an exact version like '0.28.7'. Affects every user of this instance " +
          "and requires an operator restart to activate. Returns installation state; " +
          "activation remains unverified. Nothing else is configurable.",
        parameters: {
          type: "object",
          additionalProperties: false,
          required: ["version"],
          properties: {
            version: {
              type: "string",
              description:
                "'latest' for the latest stable release, or an exact version such as '0.28.7'. " +
                "Prereleases are refused. No other value is accepted.",
            },
          },
        },
        async execute(_toolCallId, params) {
          if (updating || activation.hasPending()) return { content: [{ type: "text", text: "A Pretorin update is pending. Wait for its activation result." }] };
          const requested = String(params?.version ?? "").trim();
          const requester = `${toolContext?.messageChannel ?? "unknown"}:${
            toolContext?.requesterSenderId ?? "unavailable"
          }`;
          // The tool result carries the installation state back to the model.
          const text = await performUpdate({
            arg: requested,
            requester,
            route: "tool",
          });
          return { content: [{ type: "text", text }] };
        },
      }),
      { name: "pretorin_update" },
    );
  },
};
