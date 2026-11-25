'use strict';

const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { test } = require('node:test');
const { createServer } = require('../server.js');

const status = {
  version: '1.1.0',
  DEMO_ROBOT_LABEL: 'Демонстрационный робот',
  DEMO_COLOR: 'green',
  DEMO_GREETING: 'Hello, robot',
  api_token_present: true,
  start_count: 4,
};

async function listen(t, server) {
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise((resolve) => server.close(resolve)));
  return `http://127.0.0.1:${server.address().port}`;
}

function request(url) {
  return new Promise((resolve, reject) => {
    http.get(url, (response) => {
      let body = '';
      response.setEncoding('utf8');
      response.on('data', (part) => { body += part; });
      response.on('end', () => resolve({ code: response.statusCode, body, headers: response.headers }));
      response.on('error', reject);
    }).on('error', reject);
  });
}

async function upstream(t, payload = status, code = 200) {
  return listen(t, http.createServer((req, res) => {
    assert.equal(req.url, '/status');
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(payload));
  }));
}

test('страница получает статус api, показывает цвет, версии и счётчик', async (t) => {
  const apiUrl = await upstream(t);
  const url = await listen(t, createServer({ apiUrl, version: '1.1.0' }));
  const result = await request(url + '/');
  assert.equal(result.code, 200);
  assert.match(result.headers['content-type'], /text\/html/);
  for (const value of ['1.1.0', 'Демонстрационный робот', 'green', '4', 'true', 'Hello, robot']) {
    assert.ok(result.body.includes(value));
  }
  assert.match(result.headers['content-security-policy'], /default-src 'none'/);
});

test('healthcheck исправного web возвращает 200 без обращения к api', async (t) => {
  const url = await listen(t, createServer({ apiUrl: 'http://127.0.0.1:1', version: '1.0.0' }));
  const result = await request(url + '/healthz');
  assert.equal(result.code, 200);
  assert.deepEqual(JSON.parse(result.body), { ok: true });
});

test('пустое приветствие не выводится, статус без поля приветствия принимается', async (t) => {
  const { DEMO_GREETING: _unused, ...withoutGreeting } = status;
  const apiUrl = await upstream(t, withoutGreeting);
  const url = await listen(t, createServer({ apiUrl, version: '1.0.0' }));
  const result = await request(url + '/');
  assert.equal(result.code, 200);
  assert.ok(!result.body.includes('Приветствие'));
});

test('нестроковое приветствие — отказ api, а не вывод в HTML', async (t) => {
  const apiUrl = await upstream(t, { ...status, DEMO_GREETING: { html: '<b>x</b>' } });
  const url = await listen(t, createServer({ apiUrl }));
  assert.equal((await request(url + '/')).code, 503);
});

test('статус экранируется, посторонние поля и CSS не попадают в HTML', async (t) => {
  const apiUrl = await upstream(t, {
    ...status,
    DEMO_ROBOT_LABEL: '<script>alert("x")</script>',
    DEMO_GREETING: '<img src=y onerror=alert(2)>',
    DEMO_COLOR: 'red; background-image: url(https://invalid.example)',
    version: '<img src=x onerror=alert(1)>',
    api_token: 'synthetic-private-value',
  });
  const url = await listen(t, createServer({ apiUrl, version: '<script>version</script>' }));
  const { body } = await request(url + '/');
  assert.ok(body.includes('&lt;script&gt;'));
  for (const value of ['<script>', '<img', 'background-image', 'synthetic-private-value']) {
    assert.ok(!body.includes(value));
  }
});

test('ошибка api скрывает upstream body и возвращает 503', async (t) => {
  const apiUrl = await upstream(t, { error: 'synthetic-private-value' }, 500);
  const url = await listen(t, createServer({ apiUrl }));
  const result = await request(url + '/');
  assert.equal(result.code, 503);
  assert.ok(!result.body.includes('synthetic-private-value'));
});

test('некорректный JSON и зависший api дают ограниченный по времени отказ', async (t) => {
  for (const handler of [
    (req, res) => res.end('{broken'),
    (req, res) => { req.on('close', () => res.destroy()); },
  ]) {
    const apiUrl = await listen(t, http.createServer(handler));
    const url = await listen(t, createServer({ apiUrl, timeoutMs: 50 }));
    assert.equal((await request(url + '/')).code, 503);
  }
});

test('неизвестный путь возвращает 404', async (t) => {
  const url = await listen(t, createServer());
  assert.equal((await request(url + '/missing')).code, 404);
});
