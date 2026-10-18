// Public OpenClaw CLI, lifecycle hook, health endpoint, and channel adapter only.
import * as fs from 'node:fs';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';

const BINARY = '/home/node/.pretorin/bin/pretorin';
const CWD = '/opt/compliance-claw/no-repo';
const LAUNCHER = '/opt/compliance-claw/pretorin-mcp-launch';
const PENDING = '/home/node/.pretorin/update-activation.json';
const PATH = '/home/node/.pretorin/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin';
export const MANUAL_RESTART = 'Activation is unverified. On the deployment host, run `docker compose restart openclaw`. The update is not complete until the new version is active.';

export function runProcess(program, args, { signal, timeout = 30_000, gateway = false } = {}) {
  return new Promise((resolve) => {
    let child, stdout = '', settled = false;
    const finish = (result) => { if (!settled) { settled = true; clearTimeout(timer); resolve(result); } };
    let timer;
    try {
      child = spawn(program, args, {
        stdio: ['ignore', 'pipe', 'pipe'], signal,
        env: { PATH, HOME: '/home/node', ...(gateway ? {
          ...(process.env.OPENCLAW_GATEWAY_TOKEN ? { OPENCLAW_GATEWAY_TOKEN: process.env.OPENCLAW_GATEWAY_TOKEN } : {}),
          ...(process.env.OPENCLAW_GATEWAY_PASSWORD ? { OPENCLAW_GATEWAY_PASSWORD: process.env.OPENCLAW_GATEWAY_PASSWORD } : {}),
        } : {}) },
      });
      child.stdout.on('data', (data) => { stdout += String(data); });
      // Drain diagnostics without copying secrets or platform data into replies.
      child.stderr.on('data', () => {});
      child.once('error', () => finish({ ok: false, stdout }));
      child.once('close', (code) => finish({ ok: code === 0, stdout }));
      timer = setTimeout(() => { child.kill('SIGKILL'); }, timeout);
    } catch { finish({ ok: false, stdout }); }
  });
}

// A real stdio MCP handshake and read-only tool call, independent of the model.
export function probeMcp({ signal, command = BINARY, args = ['mcp-serve'] } = {}) {
  return new Promise((resolve) => {
    let child, timer, buffer = '', finished = false;
    const close = () => { clearTimeout(timer); signal?.removeEventListener('abort', close); child?.stdin?.end(); child?.kill('SIGTERM'); };
    const finish = (ok) => { if (!finished) { finished = true; clearTimeout(timer); if (!ok) close(); resolve({ ok, close }); } };
    try {
      child = spawn(command, args, { cwd: CWD, stdio: ['pipe', 'pipe', 'pipe'], env: { PATH, HOME: '/home/node' }, signal });
      const send = (value) => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
      child.stdin.on('error', () => finish(false));
      child.stderr.on('data', () => {});
      child.once('error', () => finish(false));child.once('close', () => finish(false));
      child.stdout.on('data', (data) => {
        buffer += String(data);
        if (buffer.length > 1_048_576) { finish(false); return; }
        let end;
        while ((end = buffer.indexOf('\n')) >= 0) {
          const line = buffer.slice(0, end);buffer = buffer.slice(end + 1);
          try {
            const reply = JSON.parse(line);
            if (reply.error) { finish(false); return; }
            if (reply.id === 1 && reply.result?.serverInfo) {
              send({ method: 'notifications/initialized' });
              send({ id: 2, method: 'tools/call', params: { name: 'check_context', arguments: {} } });
            }
            if (reply.id === 2) finish(reply.result?.isError !== true && Array.isArray(reply.result?.content));
          } catch { finish(false); }
        }
      });
      timer = setTimeout(() => finish(false), 15_000);
      signal?.addEventListener('abort', close, { once: true });
      send({ id: 1, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'compliance-claw-updater', version: '1' } } });
    } catch { finish(false); }
  });
}

const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const pause = (ms, signal) => new Promise((resolve, reject) => {
  if (signal?.aborted) { reject(new Error('Gateway is stopping')); return; }
  const stop = () => { clearTimeout(timer); reject(new Error('Gateway is stopping')); };
  const timer = setTimeout(() => { signal?.removeEventListener('abort', stop); resolve(); }, ms);
  signal?.addEventListener('abort', stop, { once: true });
});

// A renamed executable can remain loaded. Check retained file descriptors too,
// including Rosetta's descriptors on the supported linux/amd64 container image.
export function verifyLoadedMcp(expected, io = fs) {
  let count = 0;
  for (const pid of io.readdirSync('/proc').filter((name) => /^\d+$/.test(name))) {
    let args;
    try { args = io.readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0'); } catch { continue; }
    if (!args.includes('mcp-serve') || (!args.includes(BINARY) && !args.includes('pretorin'))) continue;
    count++;
    const hashes = [];
    try {
      for (const fd of io.readdirSync(`/proc/${pid}/fd`)) {
        const path = `/proc/${pid}/fd/${fd}`;
        let target;
        try { target = io.readlinkSync(path); } catch { continue; }
        if (target === BINARY || target === `${BINARY} (deleted)`) hashes.push(digest(io.readFileSync(path)));
      }
      const exe = `/proc/${pid}/exe`;
      if (io.readlinkSync(exe).replace(/ \(deleted\)$/, '') === BINARY) hashes.push(digest(io.readFileSync(exe)));
    } catch { throw new Error('Cannot verify a running Pretorin MCP process'); }
    if (!hashes.length || hashes.some((hash) => hash !== expected)) throw new Error('A running MCP process still uses an unverified binary');
  }
  return count;
}

export function configuredProbes(cfg) {
  const servers = Object.entries(cfg.mcp?.servers ?? {}).filter(([name, server]) =>
    (name === 'pretorin' || name.startsWith('pretorin-')) && server && server.enabled !== false);
  if (!servers.length) throw new Error('No configured Pretorin MCP server');
  return servers.map(([, server]) => {
    const direct = server.command === BINARY && JSON.stringify(server.args) === '["mcp-serve"]';
    const effort = server.command === LAUNCHER && server.args?.length === 1 && /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(server.args[0]);
    if ((!direct && !effort) || (server.cwd && server.cwd !== CWD)) throw new Error('Unsupported active MCP configuration');
    return { command: server.command, args: server.args };
  });
}

export function createActivation(api, {
  io = fs, run = runProcess, probe = probeMcp, request = fetch, now = Date.now, wait = pause,
  inspect = (hash) => verifyLoadedMcp(hash, io), pendingPath = PENDING,
} = {}) {
  let resuming = false;
  const hash = () => digest(io.readFileSync(BINARY));
  const read = () => JSON.parse(io.readFileSync(pendingPath, 'utf8'));
  const remove = (id) => { if (io.existsSync(pendingPath) && read().id === id) io.unlinkSync(pendingPath); };
  return {
    hasPending: () => io.existsSync(pendingPath),
    async request(version, ctx) {
      const target = /^slack:(?:channel:|group:)?([CG][A-Z0-9]+)$/i.exec(ctx?.from ?? '');
      if (ctx?.channel !== 'slack' || !target || ctx.config?.commands?.restart === false ||
          typeof ctx.assertOwnerCurrent !== 'function' || typeof api.on !== 'function' ||
          typeof api.runtime?.channel?.outbound?.loadAdapter !== 'function') return false;
      ctx.assertOwnerCurrent();
      const pending = { id: randomUUID(), version, sha256: hash(), requestedAt: now(),
        to: `channel:${target[1].toUpperCase()}`, accountId: ctx.accountId ?? 'default',
        ...(ctx.messageThreadId && /^\d+\.\d+$/.test(ctx.messageThreadId) ? { threadId: ctx.messageThreadId } : {}) };
      io.writeFileSync(pendingPath, JSON.stringify(pending), { flag: 'wx', mode: 0o600 });
      try { ctx.assertOwnerCurrent(); } catch (error) { remove(pending.id); throw error; }
      // A failed/ambiguous CLI result leaves the receipt for an operator restart.
      const result = await run('/usr/local/bin/openclaw', ['gateway', 'restart', '--safe', '--json'], { gateway: true });
      let reply;
      try { reply = JSON.parse(result.stdout); } catch { return false; }
      return result.ok && reply.ok === true && ['scheduled', 'deferred', 'coalesced'].includes(reply.result);
    },
    async resume(_event, ctx) {
      if (resuming || !io.existsSync(pendingPath)) return;
      resuming = true;
      const probes = [];
      try {
        const pending = read();
        if (!/^[0-9]+\.[0-9]+\.[0-9]+$/.test(pending.version) || !/^[a-f0-9]{64}$/.test(pending.sha256) ||
            !/^channel:[CG][A-Z0-9]+$/.test(pending.to) || !Number.isFinite(pending.requestedAt)) throw new Error('Invalid activation receipt');
        let text;
        try {
          const cfg = ctx.config;
          if (cfg.gateway?.tls?.enabled) throw new Error('Unsupported gateway health transport');
          const servers = configuredProbes(cfg);
          const url = `http://127.0.0.1:${ctx.port ?? cfg.gateway?.port ?? 18789}`;
          let restarted = false;
          for (let attempt = 0; attempt < 15; attempt++) {
            ctx.abortSignal?.throwIfAborted();
            const response = await request(`${url}/startupz`, { signal: ctx.abortSignal ? AbortSignal.any([ctx.abortSignal, AbortSignal.timeout(2_000)]) : AbortSignal.timeout(2_000) });
            const status = await response.json();
            // A plugin reload alone must not count as a gateway restart.
            if (response.ok && status.ok && Number.isFinite(status.uptimeMs) && now() - status.uptimeMs >= pending.requestedAt) { restarted = true; break; }
            await wait(1_000, ctx.abortSignal);
          }
          if (!restarted || hash() !== pending.sha256) throw new Error('Restart or installed bytes are unverified');
          const version = await run(BINARY, ['version'], { signal: ctx.abortSignal });
          if (!version.ok || !new RegExp(`(?:^|\\s)v?${pending.version.replaceAll('.', '\\.')}($|\\s)`).test(version.stdout.trim())) throw new Error('CLI version does not match');
          inspect(pending.sha256);
          for (const server of servers) {
            const mcp = await probe({ ...server, signal: ctx.abortSignal });
            probes.push(mcp);
            if (!mcp.ok || hash() !== pending.sha256) throw new Error('MCP verification failed');
          }
          if (inspect(pending.sha256) < 1) throw new Error('No active Pretorin MCP process was verified');
          ctx.abortSignal?.throwIfAborted();
          text = `Pretorin CLI ${pending.version} is active. Update complete. The gateway restarted, the CLI version matches, and the MCP check passed.`;
        } catch (error) {
          if (ctx.abortSignal?.aborted) return; // Keep the receipt for the next startup.
          text = `Pretorin CLI ${pending.version} installation succeeded. Activation verification failed. ${MANUAL_RESTART}`;
          api.logger?.warn?.(`Pretorin activation unverified: ${error.message}`);
        }
        const cfg = ctx.config;
        const slack = cfg.channels?.slack;
        const override = pending.accountId === 'default' ? (slack?.accounts?.default ?? slack) : slack?.accounts?.[pending.accountId];
        // Pinned Slack accounts inherit root settings; explicit overrides win.
        // A removed named account must not fall back to the root account.
        const account = override && { ...slack, ...override };
        const channel = pending.to.slice('channel:'.length);
        if (!account || slack.enabled === false || account.enabled === false || account.groupPolicy === 'disabled' || account.channels?.[channel] === false || account.channels?.[channel]?.enabled === false ||
            (account.groupPolicy !== 'open' && !account.channels?.[channel])) throw new Error('Original Slack channel is no longer enabled');
        const adapter = await api.runtime.channel.outbound.loadAdapter('slack');
        if (typeof adapter?.sendText !== 'function') throw new Error('Slack outbound adapter is unavailable');
        let delivered = false;
        for (let attempt = 0; attempt < 3; attempt++) {
          ctx.abortSignal?.throwIfAborted();
          try {
            const result = await adapter.sendText({ cfg, to: pending.to, accountId: pending.accountId, threadId: pending.threadId, text });
            if (!result?.messageId) throw new Error('Slack did not confirm delivery');
            delivered = true; break;
          } catch (error) { if (attempt === 2) throw error; await wait(1_000 * (attempt + 1), ctx.abortSignal); }
        }
        if (delivered) remove(pending.id);
      } catch (error) { api.logger?.error?.(`Pretorin activation result remains pending: ${error.message}. ${MANUAL_RESTART}`); }
      finally { for (const mcp of probes) mcp.close(); resuming = false; }
    },
  };
}
