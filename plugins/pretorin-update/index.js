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

/** Best-effort delivery of a follow-up message to where the request came from. */
async function deliver(api, target, text) {
  const request = api?.runtime?.gateway?.request;
  if (typeof request !== "function") return false;
  for (const method of ["message.action", "send"]) {
    try {
      await request.call(api.runtime.gateway, method, {
        action: "send",
        channel: target.channel,
        to: target.to ?? target.channelId,
        accountId: target.accountId,
        threadId: target.messageThreadId,
        text,
      });
      return true;
    } catch {
      // Try the next shape; a failure here must never fail the update itself.
    }
  }
  return false;
}

/**
 * Activation. Replacing the file is not the deliverable: a running
 * `pretorin mcp-serve` child keeps the old inode (the CLI says so itself), and
 * OpenClaw keys its MCP cache on the config object rather than the file, so
 * without a recycle the old CLI keeps serving until the ~10 minute idle TTL.
 *
 * Restarting the gateway is the supported recycle. If it is unavailable — the
 * RPC is missing, preflight refuses, or `commands.restart` is false — the update
 * is reported as STAGED with the manual step named. It is never reported as
 * complete when it is not.
 */
async function activate(api) {
  const request = api?.runtime?.gateway?.request;
  if (typeof request !== "function") {
    return { activated: false, reason: "the gateway RPC surface is unavailable" };
  }
  try {
    const pre = await request.call(api.runtime.gateway, "gateway.restart.preflight", {});
    if (pre && pre.ok === false) {
      return { activated: false, reason: pre.reason || "restart preflight refused" };
    }
  } catch {
    // Preflight is advisory; a missing method should not block the attempt.
  }
  try {
    await request.call(api.runtime.gateway, "gateway.restart.request", {
      reason: "activate updated Pretorin CLI",
    });
    return { activated: true };
  } catch (err) {
    return { activated: false, reason: String(err?.message ?? err) };
  }
}

const SHARED_INSTANCE_NOTE =
  "This changes the Pretorin CLI for EVERY user of this instance. " +
  "Activating it restarts the gateway, so do not restart it yourself until the result arrives.";

/** Shared by both routes so they cannot drift in what they promise. */
async function performUpdate(api, { arg, requester, route, target }) {
  const res = await runWrapper(arg, { requester, route });

  if (!res.ok) {
    const detail = res.error ? ` (${res.error})` : ` (exit ${res.code})`;
    const text =
      `Pretorin CLI update FAILED and was rolled back${detail}.\n` +
      "The previous version was restored. See `docker compose logs openclaw` for the audit line, " +
      "or run `scripts/pretorin-update.sh --status`.";
    if (target) await deliver(api, target, text);
    return text;
  }

  const version = resultingVersion(res.stdout);
  if (!version) {
    const text =
      "Pretorin CLI update reported success but no resulting version could be read. " +
      "Treating that as a failure; run `scripts/pretorin-update.sh --status` to check.";
    if (target) await deliver(api, target, text);
    return text;
  }

  const act = await activate(api);
  const text = act.activated
    ? `Pretorin CLI is now ${version}. Gateway restarting to activate it; ` +
      "the next MCP call uses the new binary."
    : `Pretorin CLI ${version} is INSTALLED BUT NOT YET ACTIVE (${act.reason}).\n` +
      "The running MCP server keeps the previous version until it is recycled. " +
      "Activate it with: `docker compose restart openclaw`";
  if (target) await deliver(api, target, text);
  return text;
}

export default {
  id: "pretorin-update",
  name: "Pretorin CLI Updater",
  description: "Update this deployment's Pretorin CLI in place.",

  // MUST be synchronous. The loader rejects a promise-returning register with
  // "plugin register must be synchronous".
  register(api) {
    api.registerCommand({
      name: "pretorin-update",
      description: "Update this deployment's Pretorin CLI (latest, or an explicit X.Y.Z).",
      // Without acceptsArgs the command silently does not match once an
      // argument is present, and the message falls through to the agent.
      acceptsArgs: true,
      // Core rejects unauthorized senders before this handler ever runs.
      requireAuth: true,
      agentPromptGuidance: [
        {
          text:
            "Pretorin CLI updates are available. `/pretorin-update latest` and " +
            "`/pretorin-update X.Y.Z` are operator commands that bypass the model; the " +
            "pretorin_update tool does the same thing conversationally. Never claim an " +
            "update happened unless the tool returned a resulting version.",
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
        const target = {
          channel: ctx.channel,
          channelId: ctx.channelId,
          to: ctx.to,
          accountId: ctx.accountId,
          messageThreadId: ctx.messageThreadId,
        };

        // Ack now, work later. A blocking handler would hold the plugin command
        // registry lock for the whole download, which would also block
        // `/pretorin-update status` — the command you reach for when an update
        // looks stuck.
        void performUpdate(api, { arg, requester, route: "command", target }).catch(() => {});

        const what = arg === "latest" ? "the latest stable release" : arg;
        return {
          text:
            `Updating the Pretorin CLI to ${what} (requested by <@${ctx.senderId ?? "unknown"}>).\n` +
            SHARED_INSTANCE_NOTE,
        };
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
          "and restarts the gateway to activate. Nothing else is configurable.",
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
          const requested = String(params?.version ?? "").trim();
          const requester = `${toolContext?.messageChannel ?? "unknown"}:${
            toolContext?.requesterSenderId ?? "unavailable"
          }`;
          const delivery = toolContext?.deliveryContext ?? {};
          const target = {
            channel: delivery.channel ?? toolContext?.messageChannel,
            channelId: delivery.to,
            to: delivery.to,
            accountId: delivery.accountId ?? toolContext?.agentAccountId,
            messageThreadId: delivery.threadId,
          };

          // The tool waits for the real answer rather than acking, because the
          // model needs a truthful result to report and there is no registry
          // lock at stake on this path.
          const text = await performUpdate(api, {
            arg: requested,
            requester,
            route: "tool",
            target: target.channel ? target : null,
          });
          return { content: [{ type: "text", text }] };
        },
      }),
      { name: "pretorin_update" },
    );
  },
};
