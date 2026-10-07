import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
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
  assert.equal(f.calls.length, 1);
  assert.deepEqual(f.calls[0], ['openclaw', 'plugins', 'inspect', 'slack', '--json']);
});

test('fresh setup uses exact official install without changing activation', () => {
  const f = fixture({}, null);
  assert.equal(prepareSlack({ ...f.options, required: true }), 'installed');
  assert.deepEqual(f.calls[2], ['openclaw', 'plugins', 'install', `npm:@openclaw/slack@${version}`,
    '--pin', '--no-enable', '--force']);
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
