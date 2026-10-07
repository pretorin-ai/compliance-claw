// Read config locally. Change config and install provenance through OpenClaw only.
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const LEGACY_SLACK_PATH = '/opt/compliance-claw/plugins/slack';

export function slackConfigState(config) {
  const paths = config.plugins?.load?.paths;
  return {
    configured: Boolean(config.channels?.slack),
    legacy: Array.isArray(paths) && paths.includes(LEGACY_SLACK_PATH),
    paths: Array.isArray(paths) ? paths : [],
  };
}

export function isPinnedTrustedSlack(report, version, integrity) {
  const plugin = report?.plugin;
  const trust = plugin?.trust;
  const install = report?.install;
  return plugin?.id === 'slack' && plugin.version === version
    && plugin.origin === 'global' && trust?.reason === 'trusted-official'
    && trust.installSource === 'npm'
    && trust.installSpec === `@openclaw/slack@${version}`
    && install?.source === 'npm' && install.spec === `@openclaw/slack@${version}`
    && install.version === version && install.integrity === integrity
    && typeof install.installPath === 'string'
    && fs.existsSync(path.join(install.installPath, 'openclaw.plugin.json'))
    && fs.existsSync(path.join(install.installPath, 'dist/index.js'))
    && plugin.dependencyStatus?.requiredInstalled !== false;
}

export function prepareSlack({ readConfig, run, version, integrity, required = false }) {
  let state = slackConfigState(readConfig());
  if (!required && !state.configured && !state.legacy) return 'unused';

  // The old config can contain retired fields that block all config writes.
  // Repair it before path removal, then read the current array for the guard.
  // Keep the upstream activation adapter; this extra repair is migration-only.
  if (state.legacy) {
    run('openclaw', ['doctor', '--fix', '--non-interactive']);
    state = slackConfigState(readConfig());
  }

  // Do not replace the array with a stock template. Customer paths stay in order.
  if (state.legacy) {
    const kept = state.paths.filter((entry) => entry !== LEGACY_SLACK_PATH);
    run('openclaw', ['config', 'set', 'plugins.load.paths', JSON.stringify(kept),
      '--strict-json', '--expect-current-json', JSON.stringify(state.paths)]);
    state = slackConfigState(readConfig());
    if (state.legacy) throw new Error('The obsolete Slack load path is still present.');
  }

  const inspect = () => {
    const result = run('openclaw', ['plugins', 'inspect', 'slack', '--json'], { optional: true });
    if (!result) return null;
    try { return JSON.parse(result); } catch { return null; }
  };
  if (isPinnedTrustedSlack(inspect(), version, integrity)) return 'retained';

  // Validate the release pin before OpenClaw starts its managed install.
  const metadata = JSON.parse(run('npm', ['view', `@openclaw/slack@${version}`,
    'dist.integrity', '--json']));
  const advertised = Array.isArray(metadata) && metadata.length === 1 ? metadata[0] : metadata;
  if (advertised !== integrity) throw new Error('Slack npm integrity does not match versions.env.');
  run('openclaw', ['plugins', 'install', `npm:@openclaw/slack@${version}`,
    '--pin', '--no-enable', '--force']);
  if (!isPinnedTrustedSlack(inspect(), version, integrity)) {
    throw new Error('Slack install does not have the required version, integrity, and official npm trust.');
  }
  return 'installed';
}

async function main() {
  const command = process.argv[2];
  if (command === 'foreground') {
    const args = process.argv.slice(3);
    let argv;
    if (path.basename(args[0] || '') === 'openclaw') {
      argv = [process.execPath, '/app/openclaw.mjs', ...args.slice(1)];
    } else if (path.basename(args[0] || '') === 'node'
      && ['openclaw.mjs', '/app/openclaw.mjs', '/app/dist/index.js', '/app/dist/entry.js', '/app/dist/entry.mjs'].includes(args[1])) {
      argv = [process.execPath, '/app/openclaw.mjs', ...args.slice(2)];
    }
    const { isForegroundGatewayRunArgv } = await import('/app/gateway-run-argv.mjs');
    process.exitCode = argv && isForegroundGatewayRunArgv(argv) ? 0 : 1;
    return;
  }
  const configPath = process.env.OPENCLAW_CONFIG_PATH || '/home/node/.openclaw/openclaw.json';
  const JSON5 = createRequire('/app/package.json')('json5');
  const readConfig = () => JSON5.parse(fs.readFileSync(configPath, 'utf8'));
  if (command === 'status') {
    process.stdout.write(slackConfigState(readConfig()).configured ? 'configured\n' : 'absent\n');
    return;
  }
  if (command !== 'prepare') throw new Error('Expected status or prepare.');
  const versionsPath = path.join(path.dirname(fileURLToPath(import.meta.url)), 'versions.env');
  const pins = Object.fromEntries(fs.readFileSync(versionsPath, 'utf8').split('\n')
    .filter((line) => /^SLACK_PLUGIN_(VERSION|INTEGRITY)=/.test(line))
    .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]));
  const version = pins.SLACK_PLUGIN_VERSION;
  const integrity = pins.SLACK_PLUGIN_INTEGRITY;
  if (!/^\d{4}\.\d+\.\d+(?:-\d+)?$/.test(version || '') || !/^sha512-[A-Za-z0-9+/]+=*$/.test(integrity || '')) {
    throw new Error('The Slack release pins are missing or invalid.');
  }
  const run = (program, args, { optional = false } = {}) => {
    const result = spawnSync(program, args, {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], maxBuffer: 16 * 1024 * 1024,
      timeout: 10 * 60 * 1000,
    });
    if (result.status !== 0) {
      if (optional) return null;
      // Config errors can contain secret values. Do not forward their output.
      throw new Error(`${program} ${args.slice(0, 2).join(' ')} failed. Use the same command to inspect the error.`);
    }
    return result.stdout;
  };
  const result = prepareSlack({ readConfig, run, version, integrity,
    required: process.argv.includes('--required') });
  if (result === 'installed') console.error(`compliance-claw: official Slack ${version} installed and verified.`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(`compliance-claw: ERROR: ${error.message}`);
    process.exitCode = 1;
  });
}
