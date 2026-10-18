import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import { LEGACY_SLACK_PATH, slackConfigState, prepareSlack } from './managed-slack.mjs';

const version = '2026.9.8';
const integrity = 'sha512-fixture';
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cc-managed-slack-test-'));
fs.writeFileSync(path.join(dir, 'openclaw.plugin.json'), '{"id":"slack"}');
fs.mkdirSync(path.join(dir, 'dist'));
fs.writeFileSync(path.join(dir, 'dist/index.js'), '');
process.on('exit', () => fs.rmSync(dir, { recursive: true, force: true }));
const trusted = () => ({
  plugin: { id: 'slack', version, origin: 'global', trust: {
    reason: 'trusted-official', installSource: 'npm', installSpec: `@openclaw/slack@${version}`,
  } },
  install: { source: 'npm', spec: `@openclaw/slack@${version}`, version, integrity, installPath: dir },
});

function fixture(config, report = trusted(), advertised = integrity) {
  let saved = structuredClone(config);
  let current = structuredClone(report);
  const calls = [];
  return {
    calls, saved: () => saved,
    options: { version, integrity, readConfig: () => saved, run: (program, args) => {
      calls.push([program, ...args]);
      if (args[0] === 'doctor') return '';
      if (args[0] === 'config') {
        assert.deepEqual(JSON.parse(args[6]), saved.plugins.load.paths);
        saved.plugins.load.paths = JSON.parse(args[3]);
        return '';
      }
      if (program === 'npm') return JSON.stringify(advertised);
      if (args[1] === 'install') { current = trusted(); return ''; }
      return current ? JSON.stringify(current) : null;
    } },
  };
}

test('channel presence is independent of the removed image path', () => {
  assert.equal(slackConfigState({ channels: { slack: { enabled: false } } }).configured, true);
  assert.equal(slackConfigState({ note: LEGACY_SLACK_PATH }).legacy, false);
  assert.equal(slackConfigState({ plugins: { load: { paths: [LEGACY_SLACK_PATH + '/custom'] } } }).legacy, false);
});

test('unused Slack performs no command', () => {
  const f = fixture({});
  assert.equal(prepareSlack(f.options), 'unused');
  assert.deepEqual(f.calls, []);
});

test('retained config migrates before Slack operations without the obsolete path', () => {
  for (const report of [trusted(), null]) {
    const config = {
      defaultModel: 'openai/gpt-5.6-sol',
      agents: { ownership: 'explicit', entries: { customer: {} } },
      models: { providers: { customer: { apiKey: '${CUSTOMER_MODEL_KEY}' } } },
      channels: { slack: { enabled: false, accounts: { customer: {
        botToken: '${CUSTOMER_SLACK_TOKEN}', dmPolicy: 'disabled',
      } }, channels: { C0CUSTOMER: { enabled: true } } } },
      bindings: [{ agentId: 'customer', match: { channel: 'slack', accountId: 'customer' } }],
      plugins: { allow: ['customer', 'slack'], entries: { customer: { enabled: true } },
        load: { paths: ['/customer/a', '/customer/b'] } },
    };
    const f = fixture(config, report);
    const run = f.options.run;
    f.options.run = (program, args) => {
      if (args[0] === 'doctor') {
        f.saved().agents.defaults = { model: f.saved().defaultModel };
        delete f.saved().defaultModel;
      } else {
        assert.equal(Object.hasOwn(f.saved(), 'defaultModel'), false,
          'Slack operations must read migrated configuration');
      }
      return run(program, args);
    };
    assert.equal(prepareSlack(f.options), report ? 'retained' : 'installed');
    const expected = structuredClone(config);
    expected.agents.defaults = { model: expected.defaultModel };
    delete expected.defaultModel;
    assert.deepEqual(f.saved(), expected);
    assert.deepEqual(f.calls[0], ['openclaw', 'doctor', '--fix', '--non-interactive']);
  }
});

test('Doctor failure without the obsolete path stops before Slack operations', () => {
  const config = { defaultModel: 'openai/gpt-5.6-sol', channels: { slack: { enabled: false } } };
  const f = fixture(config);
  const calls = [];
  f.options.run = (program, args) => {
    calls.push([program, ...args]);
    if (args[0] === 'doctor') throw new Error('Doctor repair refused');
    return JSON.stringify(trusted());
  };
  assert.throws(() => prepareSlack(f.options), /Doctor repair refused/);
  assert.deepEqual(calls, [['openclaw', 'doctor', '--fix', '--non-interactive']]);
  assert.deepEqual(f.saved(), config);
});

test('pinned Doctor repairs supported retained config and refuses unsafe migration', {
  skip: !fs.existsSync('/app/openclaw.mjs'),
}, () => {
  for (const refused of [false, true]) {
    const stateDir = fs.mkdtempSync(path.join(dir, 'doctor-'));
    const configPath = path.join(stateDir, 'openclaw.json');
    const config = {
      gateway: { mode: 'local', bind: 'loopback' },
      agents: { ownership: 'explicit', entries: { customer: {} },
        defaults: { workspace: path.join(stateDir, 'workspace') } },
      defaultModel: 'openai/gpt-5.6-sol',
      channels: { slack: { enabled: false } },
      plugins: { allow: [] },
      ...(refused ? { heartbeat: { every: '30m' } } : {}),
    };
    const before = JSON.stringify(config, null, 2) + '\n';
    fs.writeFileSync(configPath, before);
    const readConfig = () => JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const calls = [];
    const run = (program, args) => {
      calls.push([program, ...args]);
      if (args[0] === 'doctor') {
        const result = spawnSync(process.execPath, ['/app/openclaw.mjs', ...args], {
          env: { ...process.env, OPENCLAW_STATE_DIR: stateDir, OPENCLAW_CONFIG_PATH: configPath,
            NODE_COMPILE_CACHE: path.join(dir, 'compile-cache'), OPENCLAW_NO_RESPAWN: '1' },
          encoding: 'utf8', timeout: 180_000, maxBuffer: 16 * 1024 * 1024,
        });
        if (refused) {
          assert.equal(result.status, 1, result.stderr);
          assert.match(result.stderr + result.stdout, /retired pre-July-2026 settings: heartbeat/);
          throw new Error('Doctor repair refused');
        }
        assert.equal(result.status, 0, result.stderr);
        return result.stdout;
      }
      assert.equal(Object.hasOwn(readConfig(), 'defaultModel'), false,
        'Slack inspection must follow the real supported migration');
      assert.equal(readConfig().agents.defaults.model, config.defaultModel);
      return JSON.stringify(trusted());
    };
    const prepare = () => prepareSlack({ readConfig, run, version, integrity });
    if (refused) {
      assert.throws(prepare, /Doctor repair refused/);
      assert.deepEqual(calls, [['openclaw', 'doctor', '--fix', '--non-interactive']]);
      assert.equal(fs.readFileSync(configPath, 'utf8'), before);
    } else {
      assert.equal(prepare(), 'retained');
      assert.deepEqual(readConfig().channels, config.channels);
      assert.deepEqual(readConfig().agents.entries, config.agents.entries);
    }
  }
});

test('remove only the exact old path and keep every other setting', () => {
  const config = { channels: { slack: { enabled: false, accounts: { customer: { dmPolicy: 'disabled' } } } },
    plugins: { allow: ['customer', 'slack'], entries: { slack: { enabled: false }, customer: { enabled: true } },
      load: { paths: ['/customer/a', LEGACY_SLACK_PATH, '/customer/b', LEGACY_SLACK_PATH + '-custom'] } },
    agents: { entries: [{ id: 'customer' }] } };
  const f = fixture(config);
  assert.equal(prepareSlack(f.options), 'retained');
  const expected = structuredClone(config);
  expected.plugins.load.paths.splice(1, 1);
  assert.deepEqual(f.saved(), expected);
  assert.equal(f.calls.length, 3);
  assert.deepEqual(f.calls[0], ['openclaw', 'doctor', '--fix', '--non-interactive']);
});

test('legacy migration reads repaired paths before the guarded write', () => {
  const f = fixture({ channels: { slack: {} }, plugins: { load: { paths: [LEGACY_SLACK_PATH, '/customer/a'] } } });
  const run = f.options.run;
  f.options.run = (program, args) => {
    if (args[0] === 'doctor') f.saved().plugins.load.paths.push('/customer/doctor-kept');
    return run(program, args);
  };
  assert.equal(prepareSlack(f.options), 'retained');
  assert.deepEqual(f.saved().plugins.load.paths, ['/customer/a', '/customer/doctor-kept']);
});

test('Doctor failure stops before config removal or install', () => {
  const f = fixture({ plugins: { load: { paths: [LEGACY_SLACK_PATH] } } });
  f.options.run = (program, args) => {
    assert.deepEqual(args, ['doctor', '--fix', '--non-interactive']);
    throw new Error('Doctor repair refused');
  };
  assert.throws(() => prepareSlack(f.options), /Doctor repair refused/);
  assert.deepEqual(f.saved().plugins.load.paths, [LEGACY_SLACK_PATH]);
});

test('Doctor can remove the old override without an extra config write', () => {
  const f = fixture({ channels: { slack: {} }, plugins: { load: { paths: [LEGACY_SLACK_PATH, '/customer/a'] } } });
  const run = f.options.run;
  f.options.run = (program, args) => {
    if (args[0] === 'doctor') f.saved().plugins.load.paths = ['/customer/a'];
    return run(program, args);
  };
  assert.equal(prepareSlack(f.options), 'retained');
  assert.equal(f.calls.some((c) => c[1] === 'config'), false);
});

test('a matching official install is reused without npm access', () => {
  const f = fixture({ channels: { slack: {} } });
  assert.equal(prepareSlack(f.options), 'retained');
  assert.deepEqual(f.calls, [
    ['openclaw', 'doctor', '--fix', '--non-interactive'],
    ['openclaw', 'plugins', 'inspect', 'slack', '--json'],
  ]);
});

test('fresh setup uses exact official install without changing activation', () => {
  const f = fixture({}, null);
  assert.equal(prepareSlack({ ...f.options, required: true }), 'installed');
  assert.deepEqual(f.calls[2], ['openclaw', 'plugins', 'install', `npm:@openclaw/slack@${version}`,
    '--pin', '--no-enable', '--force']);
  assert.equal(f.calls.some((c) => c[1] === 'doctor'), false);
  assert.deepEqual(f.saved(), {});
});

test('old, newer, local, or different-integrity Slack is replaced by the release pin', () => {
  for (const change of [
    (r) => { r.plugin.version = '2026.7.1'; },
    (r) => { r.plugin.version = '2027.1.1'; },
    (r) => { r.plugin.origin = 'config'; },
    (r) => { r.install.integrity = 'sha512-different'; },
    (r) => { r.plugin.trust.reason = 'record-missing'; },
    (r) => { r.plugin.dependencyStatus = { requiredInstalled: false }; },
  ]) {
    const report = trusted(); change(report);
    const f = fixture({ channels: { slack: {} } }, report);
    assert.equal(prepareSlack(f.options), 'installed');
    assert.equal(f.calls.filter((c) => c[2] === 'install').length, 1);
  }
});

test('integrity mismatch stops before any install', () => {
  const f = fixture({ channels: { slack: {} } }, null, 'sha512-wrong');
  assert.throws(() => prepareSlack(f.options), /integrity does not match/);
  assert.equal(f.calls.some((c) => c[2] === 'install'), false);
});

test('npm 11 single-item integrity array is checked against the pin', () => {
  const f = fixture({}, null, [integrity]);
  assert.equal(prepareSlack({ ...f.options, required: true }), 'installed');
  const ambiguous = fixture({}, null, [integrity, integrity]);
  assert.throws(() => prepareSlack({ ...ambiguous.options, required: true }), /integrity does not match/);
});

test('post-install trust refusal stops gateway preparation', () => {
  const f = fixture({ channels: { slack: {} } }, null);
  const run = f.options.run;
  f.options.run = (program, args) => args[1] === 'inspect' ? null : run(program, args);
  assert.throws(() => prepareSlack(f.options), /required version, integrity, and official npm trust/);
});
