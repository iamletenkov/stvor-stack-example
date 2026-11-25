'use strict';

// Страница стека-примера Stvor; Node.js без зависимостей. Статус берёт у api при каждом открытии страницы,
// `GET /healthz` отвечает 200 без обращения к api: здоровье api проверяет его собственный healthcheck.

const http = require('node:http');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const { parseArgs } = require('node:util');

const COLORS = new Set(['blue', 'green', 'orange', 'purple']);

function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, (char) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[char]));
}

function validStatus(data) {
  return typeof data.version === 'string' && typeof data.DEMO_ROBOT_LABEL === 'string'
    && typeof data.DEMO_COLOR === 'string' && typeof data.api_token_present === 'boolean'
    && ['string', 'undefined'].includes(typeof data.DEMO_GREETING)
    && Number.isSafeInteger(data.start_count) && data.start_count >= 1;
}

function getStatus(apiUrl, timeoutMs) {
  return new Promise((resolve, reject) => {
    const request = http.get(new URL('/status', apiUrl), (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(new Error('API unavailable'));
        return;
      }
      let body = '';
      let size = 0;
      response.setEncoding('utf8');
      response.on('data', (part) => {
        size += Buffer.byteLength(part);
        if (size > 65536) request.destroy(new Error('API response too large'));
        else body += part;
      });
      response.on('error', reject);
      response.on('end', () => {
        try {
          const data = JSON.parse(body);
          if (!validStatus(data)) throw new Error('Invalid API status');
          resolve(data);
        } catch (error) {
          reject(error);
        }
      });
    });
    const timer = setTimeout(() => request.destroy(new Error('API timeout')), timeoutMs);
    request.on('close', () => clearTimeout(timer));
    request.on('error', reject);
  });
}

function render(status, version) {
  const color = COLORS.has(status.DEMO_COLOR) ? status.DEMO_COLOR : 'blue';
  const greeting = status.DEMO_GREETING
    ? `<dt>Приветствие</dt><dd>${escapeHtml(status.DEMO_GREETING)}</dd>\n`
    : '';
  return `<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Стек-пример Stvor</title>
<style>body{font:18px system-ui;max-width:48rem;margin:3rem auto;padding:1rem}
header{border-top:12px solid ${color};padding:1rem;background:#f1f5f9;color:#172033}
dt{font-weight:bold;margin-top:1rem}dd{margin-left:0;overflow-wrap:anywhere}</style></head>
<body><header><h1>Стек-пример Stvor</h1><p>Версия web: ${escapeHtml(version)}</p></header>
<dl>${greeting}<dt>Версия api</dt><dd>${escapeHtml(status.version)}</dd>
<dt>Робот</dt><dd>${escapeHtml(status.DEMO_ROBOT_LABEL)}</dd>
<dt>Цвет</dt><dd>${color}</dd>
<dt>Секрет api_token задан</dt><dd>${status.api_token_present}</dd>
<dt>Число запусков api</dt><dd>${status.start_count}</dd></dl></body></html>`;
}

function createServer({ apiUrl = 'http://api:8080', version = '0.0.0-dev', timeoutMs = 2000 } = {}) {
  return http.createServer(async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; style-src 'unsafe-inline'; frame-ancestors 'none'");
    if (req.method !== 'GET') {
      res.writeHead(405, { Allow: 'GET' });
      res.end();
    } else if (req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ ok: true }));
    } else if (req.url === '/') {
      try {
        const status = await getStatus(apiUrl, timeoutMs);
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        res.end(render(status, version));
      } catch {
        res.writeHead(503, { 'Content-Type': 'text/plain; charset=utf-8' });
        res.end('Сервис api недоступен');
      }
    } else {
      res.writeHead(404);
      res.end();
    }
  });
}

function main() {
  const { values } = parseArgs({ options: {
    host: { type: 'string', default: '0.0.0.0' },
    port: { type: 'string', default: '8080' },
    'api-url': { type: 'string', default: 'http://api:8080' },
    healthcheck: { type: 'boolean', default: false },
  } });
  if (values.healthcheck) {
    const request = http.get(`http://127.0.0.1:${values.port}/healthz`, (response) => {
      response.resume();
      process.exitCode = response.statusCode === 200 ? 0 : 1;
    });
    request.setTimeout(2000, () => request.destroy(new Error('Health timeout')));
    request.on('error', () => { process.exitCode = 1; });
    return;
  }
  const config = JSON.parse(readFileSync(join(__dirname, 'build-config.json'), 'utf8'));
  if (typeof config.version !== 'string') throw new Error('Invalid build configuration');
  createServer({ version: config.version, apiUrl: values['api-url'] }).listen(Number(values.port), values.host);
}

if (require.main === module) main();

module.exports = { createServer };
