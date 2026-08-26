/**
 * Review target synchronizer — one command, one tool, one implementation.
 *
 * Both routes shell out to the SAME in-image wrapper, so the input rules, the
 * global lock, the fast-forward-only semantics, the credential handling and the
 * audit trail live in exactly one place (scripts/sync-targets.sh), which is also
 * the implementation scripts/bootstrap.sh runs on the host:
 *
 *   /target-sync all|<name>   a command, which BYPASSES THE LLM. Core enforces
 *                             authorization before the handler runs, and no
 *                             agent tool can invoke it, so a prompt-injected
 *                             agent cannot reach this route.
 *
 *   target_sync               a model-visible tool, deliberately
 *                             prompt-injectable in this trusted-repo pilot. Its
 *                             blast radius is bounded to WHICH ALREADY-DECLARED
 *                             TARGET fast-forwards: no URL, ref, path, flag or
 *                             shell fragment is expressible, and no target can
 *                             be added, removed, re-pointed or onboarded.
 *
 * WHAT THIS PLUGIN DELIBERATELY DOES NOT DO. It does not decide which credential
 * to use, where the targets live, or what a valid name is. Every one of those
 * is the wrapper's business. A plugin that re-derived any of them would be a
 * second definition of the same rule, and the two would drift.
 *
 * Plain ESM with zero imports from the host, for the same reason as the CLI
 * updater: the image needs no Node toolchain and no npm dependency to carry it.
 */
import { spawn } from "node:child_process";

const WRAPPER = "/opt/compliance-claw/sync-targets.sh";

// Generous, because `all` on a slow network is legitimately slow, and the
// wrapper already bounds each individual git operation with its own low-speed
// abort. This is the backstop for a wrapper that never returns at all.
const TIMEOUT_MS = 600_000;

// The wrapper's own exit codes. 3 is "someone else holds the lock", which is a
// normal answer rather than a failure.
const EXIT_BUSY = 3;

/**
 * Run the wrapper. Identity is passed through the ENVIRONMENT, never as an
 * argument: an argument is something a model could write, and the audit record
 * has to mean something.
 *
 * The environment handed to the child is a FIXED ALLOWLIST — note what is not in
 * it. The gateway's own environment holds PRETORIN_API_KEY and a model provider
 * key, and none of that has any business being visible to git, to a credential
 * helper, or to anything a reviewed repository could influence.
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
          CC_SYNC_REQUESTER: requester || "unavailable",
          CC_SYNC_ROUTE: route || "unknown",
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

/**
 * Parse the wrapper's machine-readable stdout.
 *
 * Contract (tab-separated, one per target):
 *   RESULT  <name>  <outcome>  <previous>  <current>  <message>
 *   SUMMARY total=N updated=N failed=N overall=ok|failed|busy
 *
 * Anything that is not one of those two line kinds is ignored rather than
 * guessed at, so a future line added to the wrapper cannot corrupt a report.
 */
function parseResults(stdout) {
  const results = [];
  let summary = null;
  for (const line of String(stdout || "").split("\n")) {
    const parts = line.split("\t");
    if (parts[0] === "RESULT" && parts.length >= 6) {
      results.push({
        target: parts[1],
        outcome: parts[2],
        previous: parts[3] === "-" ? null : parts[3],
        current: parts[4] === "-" ? null : parts[4],
        message: parts.slice(5).join("\t"),
      });
    } else if (parts[0] === "SUMMARY") {
      summary = Object.fromEntries(
        parts.slice(1).map((kv) => {
          const i = kv.indexOf("=");
          return i < 0 ? [kv, ""] : [kv.slice(0, i), kv.slice(i + 1)];
        }),
      );
    }
  }
  return { results, summary };
}

const shortSha = (sha) => (sha ? String(sha).slice(0, 7) : "unknown");

/**
 * One line per target, in the shape the operator asked to see:
 *
 *     simple-crm updated: 276b5fd → 918ac42
 *
 * A refusal keeps the wrapper's own words rather than inventing softer ones —
 * the wrapper's messages name the remedy, and a plugin that paraphrased them
 * would be a second place for that text to go stale.
 */
function describe(r) {
  switch (r.outcome) {
    case "updated":
      return `${r.target} updated: ${shortSha(r.previous)} → ${shortSha(r.current)}`;
    case "already_current":
      return `${r.target} already current at ${shortSha(r.current)}`;
    case "sync_already_running":
      return `sync already running — ${r.message}`;
    default:
      return `${r.target} ${r.outcome}: ${r.message}`;
  }
}

function report(res) {
  if (res.error) {
    return `Target sync FAILED to start (${res.error}). Nothing was changed. ` +
      "See `docker compose logs openclaw`.";
  }

  const { results, summary } = parseResults(res.stdout);

  if (results.length === 0) {
    return `Target sync produced no result (exit ${res.code}). Nothing is known to have changed. ` +
      "See `docker compose logs openclaw` for the audit lines.";
  }

  const lines = results.map(describe);
  const changed = results.filter((r) => r.outcome === "updated").length;
  const failed = results.filter(
    (r) => r.outcome !== "updated" && r.outcome !== "already_current",
  ).length;

  let header;
  if (res.code === EXIT_BUSY) {
    header = "Nothing was started:";
  } else if (failed > 0 && changed > 0) {
    header = `${changed} target(s) updated, ${failed} refused:`;
  } else if (failed > 0) {
    header = failed === 1 && results.length === 1 ? "" : `${failed} target(s) refused:`;
  } else {
    header = "";
  }

  const body = lines.join("\n");
  const text = header ? `${header}\n${body}` : body;

  // A refusal is not an error the operator has to go hunting for, but it is also
  // not success. Say which it was, once, at the end.
  if (failed > 0 && res.code !== EXIT_BUSY) {
    return `${text}\n\nNothing was reset, discarded or force-moved — a target that could not ` +
      "fast-forward safely was left exactly as it is.";
  }
  return text;
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
      // Try the next shape; a failure here must never fail the sync itself.
    }
  }
  return false;
}

/** Shared by both routes so they cannot drift in what they promise. */
async function performSync(api, { arg, requester, route, target }) {
  const res = await runWrapper(arg, { requester, route });
  const text = report(res);
  if (target) await deliver(api, target, text);
  return text;
}

const USAGE =
  "Usage: `/target-sync all` | `/target-sync <target-name>`\n" +
  "Fast-forwards repositories already declared in targets.yaml. It never adds, " +
  "removes or re-points a target, and never discards local changes.";

export default {
  id: "target-sync",
  name: "Review Target Synchronizer",
  description: "Fast-forward the review target repositories declared in targets.yaml.",

  // MUST be synchronous. The loader rejects a promise-returning register with
  // "plugin register must be synchronous".
  register(api) {
    api.registerCommand({
      name: "target-sync",
      description: "Fast-forward review targets (all, or one target by name).",
      // Without acceptsArgs the command silently does not match once an
      // argument is present, and the message falls through to the agent.
      acceptsArgs: true,
      // Core rejects unauthorized senders before this handler ever runs.
      requireAuth: true,
      agentPromptGuidance: [
        {
          text:
            "Review targets under /workspace/targets can be brought up to date. " +
            "`/target-sync all` and `/target-sync <name>` are operator commands that " +
            "bypass the model; the target_sync tool does the same thing " +
            "conversationally, so a request like \"update the simple-crm target\" " +
            "should call it. Only repositories already declared in targets.yaml can " +
            "be synchronized — adding one is an operator action on the host, so say " +
            "so rather than attempting it. Never claim a target moved unless the tool " +
            "reported the outcome 'updated', and quote the commit SHAs it returned.",
          surfaces: ["openclaw_main"],
        },
      ],
      handler: async (ctx) => {
        const arg = (ctx.args ?? "").trim();
        if (arg === "") return { text: USAGE };

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
        // registry lock for the whole fetch, which would also block the command
        // an operator reaches for when a sync looks stuck.
        void performSync(api, { arg, requester, route: "command", target }).catch(() => {});

        const what = arg === "all" ? "every declared target" : `target '${arg}'`;
        return {
          text:
            `Synchronizing ${what} (requested by <@${ctx.senderId ?? "unknown"}>). ` +
            "Fast-forward only; the result follows in this channel.",
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
        name: "target_sync",
        label: "Synchronize review targets",
        description:
          "Bring review target repositories under /workspace/targets up to date with " +
          "their remotes, fast-forward only. Accepts 'all', or the name of a single " +
          "target already declared in targets.yaml. It cannot add, remove, re-point or " +
          "onboard a target, cannot switch branches, and cannot discard local changes: " +
          "a target that cannot fast-forward safely is reported and left alone. " +
          "Nothing else is configurable.",
        parameters: {
          type: "object",
          additionalProperties: false,
          required: ["target"],
          properties: {
            target: {
              type: "string",
              description:
                "'all' for every declared target, or the exact name of one target from " +
                "targets.yaml (for example 'simple-crm'). Not a URL, not a branch, not a " +
                "path — any other value is refused.",
            },
          },
        },
        async execute(_toolCallId, params) {
          const requested = String(params?.target ?? "").trim();
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
          const text = await performSync(api, {
            arg: requested,
            requester,
            route: "tool",
            target: target.channel ? target : null,
          });
          return { content: [{ type: "text", text }] };
        },
      }),
      { name: "target_sync" },
    );
  },
};
