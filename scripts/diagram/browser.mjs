// browser.mjs: the chrome-headless-shell that `doc-tools.sh diagram` falls
// back to on a host with no Chrome or Chromium (scripts/doc-tools.sh,
// "Diagrams"). It is the build puppeteer-core pins (its revisions), handled
// with @puppeteer/browsers, both from the renderer's installed packages.
//
//   node browser.mjs path <node_modules> <browsers-dir>
//     Print the executable of that build in <browsers-dir>. Exit 0 when it
//     is installed, 1 when it is not.
//   node browser.mjs install <node_modules> <browsers-dir>
//     Download and unpack that build into <browsers-dir> (from Google's
//     Chrome for Testing site), then print its executable. Exit 0, or 2 when
//     it could not.

import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import fs from 'node:fs';
import path from 'node:path';

function fail(code, message) {
  process.stderr.write(`browser.mjs: ${message}\n`);
  process.exit(code);
}

const [command, modulesArg, cacheArg] = process.argv.slice(2);
if (!['path', 'install'].includes(command) || !modulesArg || !cacheArg) {
  fail(2, 'usage: node browser.mjs path|install <node_modules> <browsers-dir>');
}
const modules = path.resolve(modulesArg);
const cacheDir = path.resolve(cacheArg);

// Both packages are ES modules (@puppeteer/browsers 3, puppeteer-core 25):
// each is resolved from <node_modules>, then imported, not required.
let browsers;
let buildId;
try {
  const require = createRequire(path.join(modules, 'noop.js'));
  const load = (name) => import(pathToFileURL(require.resolve(name)).href);
  browsers = await load('@puppeteer/browsers');
  buildId = (await load('puppeteer-core/internal/revisions.js')).PUPPETEER_REVISIONS['chrome-headless-shell'];
} catch (e) {
  fail(2, `cannot load @puppeteer/browsers and puppeteer-core from ${modules}: ${e.message}`);
}
if (!buildId) fail(2, 'puppeteer-core names no chrome-headless-shell build');

const browser = browsers.Browser.CHROMEHEADLESSSHELL;
const platform = browsers.detectBrowserPlatform();
if (!platform) fail(2, `no chrome-headless-shell build for this platform (${process.platform} ${process.arch})`);
const executable = browsers.computeExecutablePath({ browser, buildId, cacheDir, platform });

if (command === 'path') {
  if (fs.existsSync(executable)) {
    process.stdout.write(executable + '\n');
    process.exit(0);
  }
  process.exit(1);
}

try {
  process.stderr.write(`browser.mjs: installing chrome-headless-shell ${buildId} (${platform}) into ${cacheDir}\n`);
  const installed = await browsers.install({ browser, buildId, cacheDir, platform });
  process.stdout.write(installed.executablePath + '\n');
} catch (e) {
  fail(2, `could not install chrome-headless-shell ${buildId}: ${e.message}`);
}
