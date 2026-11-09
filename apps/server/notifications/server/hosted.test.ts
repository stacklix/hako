import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve, sep } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { test } from 'node:test';
import type { ApnsRequest } from './apns.js';
import { createApp } from './app.js';

test('Hako alone authorizes the worker and its existing device identity registers Apple Push', async () => {
  const root = resolve(tmpdir());
  const dir = await mkdtemp(join(root, 'hako-notification-test-'));
  const secret = 'S'.repeat(43), deviceId = 'D'.repeat(43);
  const headers = { 'x-hako-notification-worker': secret };
  const sent: ApnsRequest[] = [];
  const { app } = await createApp({ dataDir: dir, secret, trustedConsoles: [deviceId], logger: false,
    webDir: join(dir, 'none'),
    apns: { async send(request) { sent.push(request); return { status: 200 }; }, close() {} },
  });
  try {
    assert.equal((await app.inject('/api/v1/webhooks')).statusCode, 404);
    assert.equal((await app.inject({ url: '/api/v1/auth/login', headers, method: 'POST' })).statusCode, 404);
    assert.equal((await app.inject({ url: '/push/pair', headers, method: 'POST' })).statusCode, 404);
    const token = 'abcd'.repeat(16);
    const register = (device: string, requestHeaders = headers) => app.inject({
      method: 'PUT', url: '/internal/push/registration', headers: requestHeaders,
      payload: { deviceId: device, token, environment: 'production' },
    });
    assert.equal((await register(deviceId, { 'x-hako-notification-worker': 'spoof' })).statusCode, 404);
    assert.equal((await register('U'.repeat(43))).statusCode, 403);
    assert.equal((await register(deviceId)).statusCode, 204);
    const created = await app.inject({ method: 'POST', url: '/api/v1/webhooks', headers,
      payload: { name: '部署通知', botId: null, apnsEnabled: true, defaultChannels: ['apns'] } });
    assert.equal(created.statusCode, 201);
    const { path } = created.json();
    const request = await app.inject({ method: 'POST', url: path, headers,
      payload: { message: { type: 'text', text: '来自 Hako' } } });
    assert.equal(request.statusCode, 202);
    const url = path + '/' + request.json().notificationId;
    const deadline = Date.now() + 5_000;
    let status;
    do {
      status = (await app.inject({ url, headers })).json().status;
      if (status !== 'provider_accepted') await delay(50);
    } while (status !== 'provider_accepted' && Date.now() < deadline);
    assert.equal(status, 'provider_accepted');
    assert.equal(sent.length, 1);
    assert.equal(sent[0].token, token);
  } finally {
    await app.close();
    assert.ok(resolve(dir).startsWith(root + sep + 'hako-notification-test-'));
    await rm(dir, { recursive: true, force: true });
  }
});
