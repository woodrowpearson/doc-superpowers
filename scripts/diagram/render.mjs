// render.mjs: doc-superpowers' local Mermaid renderer, run by
// `doc-tools.sh diagram render` (scripts/doc-tools.sh, "Diagrams").
//
//   node render.mjs --browser <chrome> --modules <node_modules> --jobs <jobs.json>
//                   [--config <mermaid-config.json>]
//
// <jobs.json> is an array of {id, doc, line, png, elk, source, out}. For each
// job this opens a page in one headless browser, renders `source` with the
// Mermaid in <node_modules> (with the ELK layouts registered when `elk` is
// true), and screenshots the SVG to `out`: width 1248, device scale 2, white
// background. It prints one JSON line per job on stdout:
//   {"id": 0, "ok": true, "elk": false}
//   {"id": 1, "ok": false, "error": "...", "blocked": ["https://..."]}
// The doc-tools.sh side moves `out` onto the PNG only for an ok job.
//
// --config names a JSON object of Mermaid settings. Only the keys of
// CONFIG_KEYS are taken from it (the look and the layouts: theme,
// themeVariables, themeCSS, flowchart, elk, ...); any other top-level key
// (dompurifyConfig, secure, securityLevel, startOnLoad among them) and any
// __proto__, constructor or prototype key at any depth is dropped, and one
// warning line on stderr names what was. What is kept is deep-merged over
// this renderer's own start-up settings and handed to mermaid.initialize, so
// a block's front matter or init directive still overrides it. securityLevel
// stays "strict", and `secure` (the keys a block may not set) stays
// Mermaid's default, so no block can loosen the level either.
//
// Test seams: with DOC_TOOLS_DIAGRAM_SVG_DIR set, each rendered SVG is also
// written there, named after its PNG (a.png -> a.svg); with
// DOC_TOOLS_DIAGRAM_CLOSE_BROWSER=1 the browser is closed before the first
// job, as if it had crashed.
//
// Nothing leaves the machine: every request a page makes to anything but a
// data: or about: URL, or a file: URL under the page's own directory or the
// pinned packages' dist directories, is aborted, and a job whose page made
// one fails and names it. Behind that, the page's Content-Security-Policy names no
// network source, and Chrome runs with a dead proxy and a resolver that
// resolves nothing. Mermaid and the ELK plugin load from <node_modules> as file:
// URLs (--allow-file-access-from-files lets a file: page import file: ES
// modules); no CDN and no renderer service is used.
//
// Exit 0: every job rendered. 1: a job failed. 2: could not run (bad
// arguments, an unreadable job file, missing packages, a browser that will
// not start or that fails under a job).

import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const WIDTH = 1248;
const SCALE = 2;
const ALLOWED = /^(data|about):/i;
const FILE = /^file:/i;

function fail(message) {
  process.stderr.write(`render.mjs: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!['--browser', '--modules', '--jobs', '--config'].includes(key) || value === undefined) {
      fail(`usage: node render.mjs --browser <chrome> --modules <node_modules> --jobs <jobs.json> [--config <file>] (got ${JSON.stringify(key)})`);
    }
    args[key.slice(2)] = value;
  }
  for (const k of ['browser', 'modules', 'jobs']) if (!args[k]) fail(`--${k} is required`);
  return args;
}

const args = parseArgs(process.argv.slice(2));
const modules = path.resolve(args.modules);

let jobs;
try {
  jobs = JSON.parse(fs.readFileSync(args.jobs, 'utf8'));
} catch (e) {
  fail(`cannot read the job file ${args.jobs}: ${e.message}`);
}
if (!Array.isArray(jobs)) fail('the job file is not a JSON array');

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

// deepMerge(base, over): over's keys win; objects merge key by key, anything
// else (arrays included) is replaced.
function deepMerge(base, over) {
  const out = { ...base };
  for (const [k, v] of Object.entries(over)) {
    out[k] = isObject(v) && isObject(out[k]) ? deepMerge(out[k], v) : v;
  }
  return out;
}

// The top-level keys a config file may set: the look, the layouts and the
// diagram types' own settings. Nothing that touches sanitising or the
// security level (dompurifyConfig, secure, securityLevel) is among them.
const CONFIG_KEYS = new Set([
  'theme', 'themeVariables', 'themeCSS', 'fontFamily', 'fontSize', 'look', 'layout', 'elk',
  'flowchart', 'sequence', 'gantt', 'classDiagram', 'stateDiagram', 'er', 'journey', 'pie',
  'quadrantChart', 'requirement', 'mindmap', 'timeline', 'gitGraph', 'c4', 'sankey', 'xyChart',
  'block', 'packet', 'architecture', 'wrap', 'maxTextSize', 'maxEdges', 'darkMode', 'htmlLabels',
  'deterministicIds', 'deterministicIDSeed',
]);
const UNSAFE_KEYS = new Set(['__proto__', 'constructor', 'prototype']);

// withoutUnsafeKeys(value, where, dropped): a copy of value with every
// __proto__, constructor and prototype key removed at any depth, each one's
// dotted path pushed onto dropped.
function withoutUnsafeKeys(value, where, dropped) {
  if (Array.isArray(value)) return value.map((v, i) => withoutUnsafeKeys(v, `${where}[${i}]`, dropped));
  if (!isObject(value)) return value;
  const out = {};
  for (const [k, v] of Object.entries(value)) {
    if (UNSAFE_KEYS.has(k)) {
      dropped.push(`${where}.${k}`);
      continue;
    }
    out[k] = withoutUnsafeKeys(v, `${where}.${k}`, dropped);
  }
  return out;
}

// allowedConfig(file): the CONFIG_KEYS of file, cleaned; one warning line
// names every key that was dropped.
function allowedConfig(file) {
  const dropped = [];
  const out = {};
  for (const [k, v] of Object.entries(file)) {
    if (!CONFIG_KEYS.has(k)) {
      dropped.push(k);
      continue;
    }
    out[k] = withoutUnsafeKeys(v, k, dropped);
  }
  if (dropped.length > 0) {
    process.stderr.write(`render.mjs: Mermaid config keys not accepted, dropped: ${dropped.join(', ')}\n`);
  }
  return out;
}

// c4.wrap false: the setting every hand render before this renderer used.
// layout dagre: Mermaid 12 bundles ELK and makes it the default layout; this
// renderer keeps dagre the default, so ELK stays what a block (or the config
// file) asks for with `layout: elk`, and flowchart.curve keeps applying.
let mermaidConfig = { startOnLoad: false, securityLevel: 'strict', layout: 'dagre', c4: { wrap: false } };
if (args.config) {
  let file;
  try {
    file = JSON.parse(fs.readFileSync(args.config, 'utf8'));
  } catch (e) {
    fail(`cannot read the Mermaid config ${args.config}: ${e.message}`);
  }
  if (!isObject(file)) fail(`the Mermaid config ${args.config} is not a JSON object`);
  mermaidConfig = deepMerge(mermaidConfig, allowedConfig(file));
}
mermaidConfig.startOnLoad = false;
mermaidConfig.securityLevel = 'strict';
delete mermaidConfig.secure;
const svgDir = process.env.DOC_TOOLS_DIAGRAM_SVG_DIR || '';

const mermaidFile = path.join(modules, 'mermaid', 'dist', 'mermaid.esm.min.mjs');
const elkFile = path.join(modules, '@mermaid-js', 'layout-elk', 'dist', 'mermaid-layout-elk.esm.min.mjs');
for (const f of [mermaidFile, elkFile]) if (!fs.existsSync(f)) fail(`the pinned packages are not installed: ${f} is missing`);

// The only directories a file: request may read: the page's own (made
// below) and the dist directories of the pinned mermaid and layout-elk.
// Anything else on the disk (an <img> in a label, a url() in themeCSS) is
// refused, so no local file is drawn into a committed PNG.
const fileRoots = [path.dirname(mermaidFile), path.dirname(elkFile)].map((d) => fs.realpathSync(d));

// fileAllowed(url): true when the file: URL names an existing file under
// one of fileRoots, symbolic links resolved.
function fileAllowed(url) {
  let real;
  try {
    real = fs.realpathSync(fileURLToPath(url));
  } catch {
    return false;
  }
  return fileRoots.some((root) => real.startsWith(root + path.sep));
}

// puppeteer-core is an ES module (from 25): resolved from <node_modules>,
// then imported, not required.
let puppeteer;
try {
  const resolved = createRequire(path.join(modules, 'noop.js')).resolve('puppeteer-core');
  puppeteer = (await import(pathToFileURL(resolved).href)).default;
} catch (e) {
  fail(`cannot load puppeteer-core from ${modules}: ${e.message}`);
}

// The page every job renders in: an empty white body. It lives in a private
// temporary directory, so its file: URL names nothing of the repository.
// Its Content-Security-Policy names no network source (scripts, styles,
// images and fonts from file: and data: only, no fetch or XHR): a second
// wall behind the request interception.
const CSP_META = `<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src file: 'unsafe-eval' 'unsafe-inline'; style-src 'unsafe-inline' file:; img-src data: file:; font-src data: file:; connect-src 'none'">`;
const pageDir = fs.mkdtempSync(path.join(os.tmpdir(), 'doc-superpowers-diagram-'));
const pageFile = path.join(pageDir, 'page.html');
fileRoots.push(fs.realpathSync(pageDir));
fs.writeFileSync(pageFile,
  '<!doctype html><html><head><meta charset="utf-8">' +
  CSP_META +
  '<style>html,body{background:#ffffff;margin:0}body{margin:8px}</style>' +
  '</head><body><div id="container"></div></body></html>\n');

let browser;
try {
  browser = await puppeteer.launch({
    executablePath: args.browser,
    headless: true,
    args: [
      '--allow-file-access-from-files',
      '--disable-background-networking',
      '--disable-component-update',
      '--disable-domain-reliability',
      '--disable-sync',
      '--no-first-run',
      '--no-default-browser-check',
      '--hide-scrollbars',
      // A third wall: whatever escaped the interception and the CSP goes to
      // a proxy that listens nowhere (the discard port), loopback included,
      // and no host name resolves.
      '--proxy-server=127.0.0.1:9',
      '--proxy-bypass-list=<-loopback>',
      '--host-resolver-rules=MAP * ~NOTFOUND',
    ],
  });
} catch (e) {
  fs.rmSync(pageDir, { recursive: true, force: true });
  fail(`could not launch the browser ${args.browser}: ${e.message}`);
}

async function renderJob(job) {
  const blocked = [];
  const page = await browser.newPage();
  try {
    await page.setRequestInterception(true);
    page.on('request', (request) => {
      const url = request.url();
      if (ALLOWED.test(url) || (FILE.test(url) && fileAllowed(url))) {
        request.continue().catch(() => {});
      } else {
        if (!blocked.includes(url)) blocked.push(url);
        request.abort('blockedbyclient').catch(() => {});
      }
    });
    // What the CSP refuses never reaches the interception: the page records
    // each refusal, and the job reports it as blocked too.
    await page.evaluateOnNewDocument(() => {
      window.__cspBlocked = [];
      document.addEventListener('securitypolicyviolation', (e) => {
        window.__cspBlocked.push(String(e.blockedURI || e.violatedDirective));
      });
    });
    await page.setViewport({ width: WIDTH, height: 800, deviceScaleFactor: SCALE });
    await page.goto(pathToFileURL(pageFile).href, { waitUntil: 'load' });
    const result = await page.evaluate(async (mermaidUrl, elkUrl, source, elk, config) => {
      const { default: mermaid } = await import(mermaidUrl);
      if (elk) {
        const { default: layouts } = await import(elkUrl);
        mermaid.registerLayoutLoaders(layouts);
      }
      mermaid.initialize(config);
      try {
        const { svg } = await mermaid.render('diagram', source);
        const container = document.getElementById('container');
        container.innerHTML = svg;
        // Images a label may hold: wait until each has loaded or failed.
        await Promise.all([...container.querySelectorAll('img')].map((img) =>
          img.complete ? null : new Promise((resolve) => { img.onload = resolve; img.onerror = resolve; })));
        await document.fonts.ready;
        const box = container.querySelector('svg').getBoundingClientRect();
        return { ok: true, svg, x: box.left, y: box.top, width: box.width, height: box.height };
      } catch (e) {
        return { ok: false, error: String((e && e.message) || e) };
      }
    }, pathToFileURL(mermaidFile).href, pathToFileURL(elkFile).href, job.source, Boolean(job.elk), mermaidConfig);
    for (const url of await page.evaluate(() => window.__cspBlocked || [])) {
      if (!blocked.includes(url)) blocked.push(url);
    }
    if (!result.ok) return { id: job.id, ok: false, error: result.error, blocked };
    if (!(result.width > 0 && result.height > 0)) {
      return { id: job.id, ok: false, error: 'the diagram rendered empty', blocked };
    }
    const clip = {
      x: Math.floor(result.x),
      y: Math.floor(result.y),
      width: Math.ceil(result.width),
      height: Math.ceil(result.height),
    };
    // A viewport tall enough to hold the whole diagram: a clip below the
    // viewport would be cut.
    await page.setViewport({ width: WIDTH, height: Math.max(800, clip.y + clip.height + 8), deviceScaleFactor: SCALE });
    await page.screenshot({ path: job.out, type: 'png', clip, omitBackground: false });
    if (svgDir) {
      fs.mkdirSync(svgDir, { recursive: true });
      fs.writeFileSync(path.join(svgDir, path.basename(String(job.png), '.png') + '.svg'), result.svg);
    }
    if (blocked.length > 0) {
      return { id: job.id, ok: false, error: 'the page requested an outside URL or a local file, which was refused', blocked };
    }
    return { id: job.id, ok: true, elk: Boolean(job.elk) };
  } catch (e) {
    // The browser itself gone (crashed, killed): not this job's failure.
    if (!browser.connected) throw e;
    return { id: job.id, ok: false, error: String((e && e.message) || e), blocked };
  } finally {
    await page.close().catch(() => {});
  }
}

// Test seam: with DOC_TOOLS_DIAGRAM_CLOSE_BROWSER=1 the browser is closed
// before the first job, as if it had crashed.
if (process.env.DOC_TOOLS_DIAGRAM_CLOSE_BROWSER === '1') await browser.close().catch(() => {});

// A failure of the browser itself (a page it cannot open, a crash under a
// job) is "could not run", exit 2, never a job's failure.
let failed = 0;
let browserError = null;
try {
  for (const job of jobs) {
    const result = await renderJob(job);
    if (!result.ok) failed += 1;
    process.stdout.write(JSON.stringify(result) + '\n');
  }
} catch (e) {
  browserError = e;
} finally {
  await browser.close().catch(() => {});
  fs.rmSync(pageDir, { recursive: true, force: true });
}
if (browserError) fail(`the browser failed: ${(browserError && browserError.message) || browserError}`);
process.exit(failed > 0 ? 1 : 0);
