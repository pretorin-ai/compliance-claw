import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import vm from 'node:vm';

// Run the unmodified plugin with a simulated installer. These tests protect
// final replies and installation state. They do not prove signed downloads,
// live Slack delivery, or activation of a running MCP server.
const source = await readFile(new URL('../plugins/pretorin-update/index.js', import.meta.url), 'utf8');
const tick = () => new Promise((resolve) => setImmediate(resolve));

async function harness({ gateway = 'restricted', spawnError, clock } = {}) {
  const calls = [];
  const children = [];
  const rpc = [];
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
    assert.equal(name, 'node:child_process');
    return childProcess;
  });
  await module.evaluate();
  let command;
  let factory;
  module.namespace.default.register({
    registerCommand: (value) => { command = value; },
    registerTool: (value) => { factory = value; },
    ...(gateway === 'missing' ? {} : { runtime: { gateway: { request: async (...args) => {
      rpc.push(args);
      if (gateway === 'restricted') throw new Error('Gateway requests are only available to bundled or trusted official plugins');
      return { ok: true, status: 'deferred' };
    } } } }),
  });
  return {
    command, factory, calls, children, rpc,
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
test('usage does not start an update or promise an automatic restart', async () => {
  const h = await harness();
  const result = await h.command.handler({ args: '' });
  assert.match(result.text, /Usage:/);
  assert.match(result.text, /operator restart/i);
  const description = h.factory({}).description;
  assert.match(description, /requires an operator restart to activate/);
  assert.match(description, /returns installation state/i);
  assert.match(description, /activation remains unverified/i);
  assert.doesNotMatch(description, /restarts the gateway|update complete/i);
  const guidance = h.command.agentPromptGuidance[0].text;
  assert.match(guidance, /never claim an installation succeeded unless the tool returned an installed version/i);
  assert.match(guidance, /activation remains unverified and requires an operator restart/i);
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
