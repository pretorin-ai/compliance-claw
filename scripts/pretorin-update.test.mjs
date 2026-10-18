import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFile, mkdtemp, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import vm from 'node:vm';
const activationSource = await readFile(new URL('../plugins/pretorin-update/activation.js', import.meta.url), 'utf8');
const { createActivation, MANUAL_RESTART, verifyLoadedMcp, configuredProbes } = await import(`data:text/javascript;base64,${Buffer.from(activationSource).toString('base64')}`);
import { createHash } from 'node:crypto';

// Run the unmodified plugin with a simulated installer. These tests protect
// final replies and installation state. They do not prove signed downloads,
// live Slack delivery, or activation of a running MCP server.
const source = await readFile(new URL('../plugins/pretorin-update/index.js', import.meta.url), 'utf8');
const tick = () => new Promise((resolve) => setImmediate(resolve));

async function harness({ gateway = 'restricted', spawnError, clock, activation = { hasPending: () => false, request: async () => false } } = {}) {
  const calls = [];
  const children = [];
  const rpc = [];
  const hooks = [];
  const context = vm.createContext({ setTimeout, clearTimeout, ...clock });
  const childProcess = new vm.SyntheticModule(['spawn'], function () {
    this.setExport('spawn', (program, args, options) => {
      calls.push({ program, args: Array.from(args), options });
      if (spawnError) throw new Error(spawnError);
      const child = new EventEmitter();
      child.stdout = new EventEmitter();
      child.kills = [];
      child.kill = (signal) => { child.kills.push(signal); };
      children.push(child);
      return child;
    });
  }, { context });
  const module = new vm.SourceTextModule(source, { context });
  await module.link((name) => {
    if (name === 'node:child_process') return childProcess;
    assert.equal(name, './activation.js');
    return new vm.SyntheticModule(['createActivation', 'MANUAL_RESTART'], function () {
      this.setExport('MANUAL_RESTART', MANUAL_RESTART);
      this.setExport('createActivation', () => activation);
    }, { context });
  });
  await module.evaluate();
  let command;
  let factory;
  module.namespace.default.register({
    on: (...value) => hooks.push(value),
    registerCommand: (value) => { command = value; },
    registerTool: (value) => { factory = value; },
    ...(gateway === 'missing' ? {} : { runtime: { gateway: { request: async (...args) => {
      rpc.push(args);
      if (gateway === 'restricted') throw new Error('Gateway requests are only available to bundled or trusted official plugins');
      return { ok: true, status: 'deferred' };
    } } } }),
  });
  return {
    command, factory, calls, children, rpc, hooks,
    finish(index = 0, { stdout = 'ACTIVE_VERSION=0.30.4\n', code = 0 } = {}) {
      children[index].stdout.emit('data', stdout);
      children[index].emit('close', code);
    },
  };
}

function assertRestartRequired(text) {
  assert.match(text, /0\.30\.4/);
  assert.match(text, /installation succeeded/i);
  assert.match(text, /operator restart required/i);
  assert.match(text, /activation is unverified/i);
  assert.match(text, /docker compose restart openclaw/);
  assert.doesNotMatch(text, /is now|next MCP call uses|update complete|gateway restarting/i);
}

test('command waits for installation and returns the final restart instructions', async () => {
  const h = await harness();
  let settled = false;
  const pending = h.command.handler({ args: 'latest', channel: 'slack', senderId: 'U123' });
  void pending.then(() => { settled = true; });
  await tick();
  const returnedBeforeInstall = settled;
  h.finish();
  const result = await pending;
  await tick();
  assert.equal(returnedBeforeInstall, false, 'an acknowledgement must not replace the final result');
  assertRestartRequired(result.text);
  assert.deepEqual(h.rpc, []);
  assert.equal(h.command.requireAuth, true);
  assert.deepEqual(h.calls[0].args, ['latest']);
  assert.equal(h.calls[0].program, '/opt/compliance-claw/pretorin-update.sh');
  assert.equal(h.calls[0].options.env.PRETORIN_UPDATE_REQUESTER, 'slack:U123');
  assert.equal(h.calls[0].options.env.PRETORIN_UPDATE_ROUTE, 'command');
  assert.equal(h.calls[0].options.stdio[2], 'inherit');
});

for (const gateway of ['restricted', 'missing', 'permissive']) {
  test(`tool returns installation state with ${gateway} Gateway RPC`, async () => {
    const h = await harness({ gateway });
    const tool = h.factory({ messageChannel: 'slack', requesterSenderId: 'U456' });
    const pending = tool.execute('call-1', { version: ' 0.30.4 ' });
    h.finish();
    const result = await pending;
    assertRestartRequired(result.content[0].text);
    assert.deepEqual(h.rpc, [], 'RPC availability or acceptance must not become activation evidence');
    assert.deepEqual(h.calls[0].args, ['0.30.4']);
    assert.equal(h.calls[0].options.env.PRETORIN_UPDATE_REQUESTER, 'slack:U456');
    assert.equal(h.calls[0].options.env.PRETORIN_UPDATE_ROUTE, 'tool');
  });
}

for (const route of ['command', 'tool']) {
  for (const outcome of ['failed', 'missing-version']) {
    test(`${route} reports ${outcome} without an installation or activation claim`, async () => {
      const h = await harness();
      const pending = route === 'command'
        ? h.command.handler({ args: 'latest', channel: 'slack', senderId: 'U123' })
        : h.factory({}).execute('call-1', { version: 'latest' });
      h.finish(0, outcome === 'failed'
        ? { code: 1, stdout: 'ACTIVE_VERSION=0.30.4\n' }
        : { stdout: 'installer returned no version\n' });
      const result = await pending;
      const text = route === 'command' ? result.text : result.content[0].text;
      assert.match(text, /fail/i);
      assert.doesNotMatch(text, /installation succeeded|is now|next MCP call uses|update complete/i);
      assert.deepEqual(h.rpc, []);
    });
  }
}

test('spawn failure returns a failure without claiming rollback', async () => {
  const h = await harness({ spawnError: 'wrapper unavailable' });
  const result = await h.command.handler({ args: 'latest' });
  assert.match(result.text, /failed.*wrapper unavailable/i);
  assert.doesNotMatch(result.text, /restored|rolled back|installation succeeded/i);
});

// Value: protects=the final reply settles on an asynchronous child error;
// fails_when=an error leaves the command pending or reports installation;
// why_new=the existing spawn-failure test throws before a child is created;
// seam=none; no_claim=real process creation failure, simulated event only.
test('asynchronous child error returns the final failure', async () => {
  const h = await harness();
  const pending = h.command.handler({ args: 'latest' });
  h.children[0].emit('error', new Error('child unavailable'));
  const result = await pending;
  assert.match(result.text, /failed.*child unavailable/i);
  assert.doesNotMatch(result.text, /installation succeeded|restored|rolled back/i);
  assert.deepEqual(h.rpc, []);
});

// Value: protects=a stalled child is killed and cannot report installation;
// fails_when=the timeout fails to kill or signal termination reports success;
// why_new=no existing test runs the timer or handles a signal close;
// seam=none; no_claim=real six-minute stall, controlled timer only.
test('timeout kills the child and returns failure after signal close', async () => {
  let timeout;
  const cleared = [];
  const h = await harness({ clock: {
    setTimeout: (callback, delay) => { timeout = { callback, delay }; return 42; },
    clearTimeout: (timer) => { cleared.push(timer); },
  } });
  const pending = h.command.handler({ args: 'latest' });
  assert.equal(timeout.delay, 360_000);
  timeout.callback();
  assert.deepEqual(h.children[0].kills, ['SIGKILL']);
  h.children[0].emit('close', null, 'SIGKILL');
  const result = await pending;
  assert.match(result.text, /installation failed/i);
  assert.doesNotMatch(result.text, /installation succeeded|restored|rolled back/i);
  assert.deepEqual(cleared, [42]);
  assert.deepEqual(h.rpc, []);
});

// Value: protects=usage and model metadata separate installation from activation;
// fails_when=guidance permits success without a version or completion before restart;
// why_new=the earlier metadata assertions checked only isolated phrases;
// seam=none; no_claim=actual model compliance or live Slack delivery.
test('usage separates an owner restart from the manual model-tool path', async () => {
  const h = await harness();
  const result = await h.command.handler({ args: '' });
  assert.match(result.text, /Usage:/);
  assert.match(result.text, /owner.*safe restart/i);
  const description = h.factory({}).description;
  assert.match(description, /requires an operator restart to activate/);
  assert.match(description, /returns installation state/i);
  assert.match(description, /activation remains unverified/i);
  assert.doesNotMatch(description, /restarts the gateway|update complete/i);
  const guidance = h.command.agentPromptGuidance[0].text;
  assert.match(guidance, /never claim an installation succeeded unless the tool returned an installed version/i);
  assert.match(guidance, /activation remains unverified until the final activation result/i);
  assert.match(guidance, /do not claim the update is complete/i);
  assert.deepEqual(h.calls, []);
});

test('status can complete while an update is pending', async () => {
  const h = await harness();
  const update = h.command.handler({ args: 'latest' });
  const status = h.command.handler({ args: 'status', senderId: 'U123' });
  h.finish(1, { stdout: 'active 0.30.3\nseed 0.30.3\n' });
  const result = await status;
  h.finish(0);
  await update;
  assert.match(result.text, /active 0\.30\.3/);
  assert.deepEqual(h.calls[1].args, ['--status']);
});

const binary = '/home/node/.pretorin/bin/pretorin';
const pendingPath = '/test/pending.json';
const sha = (value) => createHash('sha256').update(value).digest('hex');
function activationHarness({ result = 'deferred', version = '0.30.4', smoke = true, inspectError, sendFailures = 0, startupAt = 2_000 } = {}) {
  const files = new Map([[binary, Buffer.from('signed new CLI')]]);
  const sent = [], ran = [], hooks = [], logs = [];
  const io = {
    existsSync: (path) => files.has(path),
    readFileSync: (path, encoding) => { if (!files.has(path)) throw Error('ENOENT'); return encoding ? String(files.get(path)) : Buffer.from(files.get(path)); },
    writeFileSync: (path, value, opts) => { if (opts?.flag === 'wx' && files.has(path)) throw Error('EEXIST'); files.set(path, value); },
    unlinkSync: (path) => files.delete(path),
  };
  const cfg = { gateway: { port: 18789 }, commands: { restart: true }, mcp: { servers: { pretorin: { command: binary, args: ['mcp-serve'] } } }, channels: { slack: { enabled: true, groupPolicy: 'allowlist', channels: { C123: { requireMention: true } } } } };
  const ctx = { config: cfg, port: 18789, channel: 'slack', senderId: 'U123', from: 'slack:channel:C123', to: 'slash:U123', accountId: 'default', messageThreadId: '1234.567', assertOwnerCurrent() {} };
  const api = { on: (...args) => hooks.push(args), logger: { warn: (x) => logs.push(x), error: (x) => logs.push(x) }, runtime: { channel: { outbound: { loadAdapter: async (channel) => {
    assert.equal(channel, 'slack');
    return { sendText: async (request) => { if (sendFailures-- > 0) throw Error('Slack unavailable'); sent.push(request); return { messageId: '1234.999' }; } };
  } } } } };
  const deps = { io, pendingPath, now: () => 10_000, wait: async () => {}, inspect: () => { if (inspectError) throw Error(inspectError); return 2; },
    probe: async () => ({ ok: smoke, close() {} }),
    request: async (url) => { assert.equal(url, 'http://127.0.0.1:18789/startupz'); return { ok: true, json: async () => ({ ok: true, uptimeMs: 10_000 - startupAt }) }; },
    run: async (program, args, options) => { ran.push({ program, args, options }); if (program === '/usr/local/bin/openclaw') return { ok: true, stdout: JSON.stringify({ ok: true, result }) }; if (args[0] === 'version') return { ok: true, stdout: `pretorin ${version}\n` }; return { ok: smoke, stdout: '' }; },
  };
  // Request time precedes the simulated new Gateway generation.
  const controller = createActivation(api, { ...deps, now: () => 1_000 });
  return { files, sent, ran, logs, ctx, api, deps, controller, resume: () => createActivation(api, deps).resume({}, ctx) };
}

for (const result of ['scheduled', 'deferred', 'coalesced']) {
  test(`owner command preserves a durable pending receipt for ${result}`, async () => {
    const h = activationHarness({ result });
    assert.equal(await h.controller.request('0.30.4', h.ctx), true);
    assert.equal(h.sent.length, 0, 'restart acceptance is not activation success');
    const receipt = JSON.parse(h.files.get(pendingPath));
    assert.equal(receipt.sha256, sha('signed new CLI'));
    assert.equal(receipt.to, 'channel:C123', 'native slash reply target must not become the final channel');
    assert.equal(receipt.threadId, '1234.567');
    assert.deepEqual(h.ran[0].args, ['gateway', 'restart', '--safe', '--json']);
    assert.equal(h.ran[0].options.gateway, true);
    await h.resume();
    assert.match(h.sent[0].text, /0\.30\.4 is active\. Update complete/);
    assert.equal(h.sent[0].accountId, 'default');
    assert.equal(h.sent[0].threadId, '1234.567');
    assert.equal(h.files.has(pendingPath), false);
    assert.deepEqual(h.ran.slice(1).map((x) => x.args), [['version']]);
  });
}

for (const failure of ['old-version', 'bad-mcp', 'old-process', 'no-restart', 'changed-file']) {
  test(`startup sends an unverified result instead of success for ${failure}`, async () => {
    const h = activationHarness({ version: failure === 'old-version' ? '0.30.3' : '0.30.4', smoke: failure !== 'bad-mcp', inspectError: failure === 'old-process' ? 'old MCP process' : undefined, startupAt: failure === 'no-restart' ? 0 : 2_000 });
    await h.controller.request('0.30.4', h.ctx);
    if (failure === 'changed-file') h.files.set(binary, Buffer.from('other CLI'));
    await h.resume();
    assert.equal(h.sent.length, 1);
    assert.match(h.sent[0].text, /installation succeeded\. Activation verification failed/);
    assert.match(h.sent[0].text, /docker compose restart openclaw/);
    assert.doesNotMatch(h.sent[0].text, /^Pretorin CLI [0-9.]+ is active|Update complete/);
  });
}

test('disabled restart and missing owner authority do not create a receipt or run CLI', async () => {
  for (const disabled of [true, false]) {
    const h = activationHarness();
    if (disabled) h.ctx.config.commands.restart = false; else delete h.ctx.assertOwnerCurrent;
    assert.equal(await h.controller.request('0.30.4', h.ctx), false);
    assert.equal(h.files.has(pendingPath), false);
    assert.equal(h.ran.length, 0);
  }
});

test('owner revocation before CLI removes only its own receipt and does not restart', async () => {
  const h = activationHarness();let checks = 0;
  h.ctx.assertOwnerCurrent = () => { if (++checks === 2) throw Error('owner revoked'); };
  await assert.rejects(h.controller.request('0.30.4', h.ctx), /owner revoked/);
  assert.equal(h.ran.length, 0);assert.equal(h.files.has(pendingPath), false);
});

test('delivery failure retains the receipt; a new startup can send it', async () => {
  const h = activationHarness({ sendFailures: 3 });
  await h.controller.request('0.30.4', h.ctx);
  await h.resume();
  assert.equal(h.files.has(pendingPath), true);
  assert.equal(h.sent.length, 0);
  assert.match(h.logs.at(-1), /remains pending/);
  await h.resume();
  assert.equal(h.sent.length, 1);assert.equal(h.files.has(pendingPath), false);
  await h.resume();assert.equal(h.sent.length, 1, 'a consumed receipt is not replayed');
});

test('gateway stop keeps the pending result and does not send a false failure', async () => {
  const h = activationHarness();await h.controller.request('0.30.4', h.ctx);
  const abort = new AbortController();abort.abort();h.ctx.abortSignal = abort.signal;
  await h.resume();assert.equal(h.sent.length, 0);assert.equal(h.files.has(pendingPath), true);
});

test('a removed original Slack channel receives no update result', async () => {
  const h = activationHarness();await h.controller.request('0.30.4', h.ctx);
  delete h.ctx.config.channels.slack.channels.C123;
  await h.resume();assert.equal(h.sent.length, 0);assert.equal(h.files.has(pendingPath), true);
});

test('loaded executable check refuses stale deleted bytes even when the new file is installed', () => {
  const io = {
    readdirSync: (path) => path === '/proc' ? ['12'] : ['7'],
    readFileSync: (path) => path.endsWith('cmdline') ? `${binary}\0mcp-serve\0` : Buffer.from('old CLI'),
    readlinkSync: (path) => path.endsWith('/exe') ? '/run/rosetta/rosetta' : `${binary} (deleted)`,
  };
  assert.throws(() => verifyLoadedMcp(sha('signed new CLI'), io), /unverified binary/);
  assert.doesNotThrow(() => verifyLoadedMcp(sha('old CLI'), io));
});

// Value: protects=installer result flows to the owner restart controller and startup hook;
// fails_when=the command returns manual instructions or never registers post-restart delivery;
// seam=controller only; real Slack and executable activation have separate Docker tests.
test('owner command connects installation to restart and startup confirmation', async () => {
  const requests = [];const resume = async () => {};
  const h = await harness({ activation: { hasPending: () => false, resume, request: async (version, ctx) => { requests.push({version, ctx});return true; } } });
  const pending = h.command.handler({ args: '0.30.4', channel: 'slack', senderId: 'U123' });
  assert.equal(requests.length, 0);h.finish();
  const reply = await pending;assert.equal(requests.length, 1, 'installed version was not handed to the restart controller');assert.equal(requests[0].version, '0.30.4');
  assert.match(reply.text, /restart requested/);assert.match(reply.text, /Activation is unverified/);
  assert.doesNotMatch(reply.text, /Update complete|is active/);
  assert.deepEqual(Array.from(h.command.requiredScopes), ['operator.admin']);
  assert.equal(h.hooks[0][0], 'gateway_start');assert.equal(h.hooks[0][1], resume);
});

test('pending activation refuses another update but permits status', async () => {
  const h = await harness({ activation: { hasPending: () => true } });
  const reply = await h.command.handler({args:'0.30.4'});
  assert.match(reply.text, /update is pending/);assert.equal(h.calls.length, 0);
  const status = h.command.handler({args:'status'});h.finish(0,{stdout:'active 0.30.4'});
  assert.match((await status).text,/active 0.30.4/);
});

test('a removed Slack account cannot fall back to the default account', async () => {
  const h = activationHarness();h.ctx.accountId='removed-account';
  await h.controller.request('0.30.4',h.ctx);await h.resume();
  assert.equal(h.sent.length,0);assert.equal(h.files.has(pendingPath),true);
});

test('a failed probe cannot claim activation when no MCP process remains', async () => {
  const h=activationHarness();await h.controller.request('0.30.4',h.ctx);
  await createActivation(h.api,{...h.deps,inspect:()=>0}).resume({},h.ctx);
  assert.match(h.sent[0].text,/Activation verification failed/);
});

test('verification supports the shipped per-effort launcher and refuses other commands', () => {
  const cfg={mcp:{servers:{'pretorin-fathom-soc2':{command:'/opt/compliance-claw/pretorin-mcp-launch',args:['fathom-soc2'],cwd:'/opt/compliance-claw/no-repo'},pretorin:null}}};
  assert.deepEqual(configuredProbes(cfg),[{command:'/opt/compliance-claw/pretorin-mcp-launch',args:['fathom-soc2']}]);
  cfg.mcp.servers['pretorin-fathom-soc2'].command='/tmp/other-cli';
  assert.throws(()=>configuredProbes(cfg),/Unsupported active MCP configuration/);
});

test('loaded process verification covers the bare argv used by the per-effort launcher', () => {
  const io={readdirSync:p=>p==='/proc'?['12']:['7'],readFileSync:p=>p.endsWith('cmdline')?'pretorin\0mcp-serve\0':Buffer.from('new CLI'),readlinkSync:p=>p.endsWith('/exe')?'/run/rosetta/rosetta':binary};
  assert.equal(verifyLoadedMcp(sha('new CLI'),io),1);
  assert.throws(()=>verifyLoadedMcp(sha('other CLI'),io),/unverified binary/);
});

// Execute the real smoke checks with a gateway that becomes readable only at
// its health check. No Docker command or network request leaves this test.
test('smoke reads the active MCP path after readiness in the gateway namespace', async () => {
  const source = await readFile(new URL('./smoke.sh', import.meta.url), 'utf8');
  const start = source.indexOf('head2 "A4. gateway starts, config and templates are seeded"');
  const end = source.indexOf('# The host port is only meaningful', start);
  assert.ok(start >= 0 && end > start);
  const firstRead = source.indexOf('CFG_CMD=');
  const early = firstRead >= 0 && firstRead < start ? source.slice(firstRead, source.indexOf('\nfi', firstRead) + 3) : '';
  const checks = early + '\n' + source.slice(start, end);
  const dir = await mkdtemp(join(tmpdir(), 'cc-smoke-order-'));
  const shell = `
set -u
PASS=0; FAIL=0
head2() { :; }; note() { :; }; sleep() { :; }
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); printf '%s\\n' "\${2:-}"; }
val() { return 77; }
docker() {
  case "$*" in
    'compose ps --status running --services') printf 'openclaw\\n' ;;
    'compose ps --format json')
      : > "$CC_SMOKE_PHASE"
      printf '{"Service":"openclaw","State":"running","Health":"healthy"}\\n' ;;
    'compose exec -T openclaw openclaw config get mcp.servers.pretorin.command')
      [ -f "$CC_SMOKE_PHASE" ] || return 77
      printf '%s\\n' "$CC_SMOKE_VALUE"
      return "$CC_SMOKE_READ_EXIT" ;;
    *) return 77 ;;
  esac
}
${checks}
printf 'pass=%s fail=%s\\n' "$PASS" "$FAIL"
[ "$PASS" = 2 ] && [ "$FAIL" = 0 ]
`;
  try {
    for (const [name, value, readExit, status, detail] of [
      ['valid', binary, '0', 0, 'pass=2 fail=0'],
      ['wrong-path', '/opt/compliance-claw/pretorin-seed/pretorin', '0', 1, 'config says: /opt/compliance-claw/pretorin-seed/pretorin'],
      ['read-error', binary, '1', 1, 'configuration read failed (exit 1)'],
    ]) {
      const result = spawnSync('bash', ['-c', shell], {
        encoding: 'utf8', timeout: 10_000,
        env: { ...process.env, CC_SMOKE_PHASE: join(dir, name), CC_SMOKE_VALUE: value, CC_SMOKE_READ_EXIT: readExit },
      });
      assert.equal(result.status, status, `${name}: ${result.stdout}${result.stderr}`);
      assert.ok(result.stdout.includes(detail), `${name}: ${result.stdout}${result.stderr}`);
    }
  } finally { await rm(dir, { recursive: true, force: true }); }
});
