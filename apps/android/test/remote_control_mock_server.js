#!/usr/bin/env node

const fs = require('fs');
const http = require('http');
const path = require('path');

const rootDir = path.resolve(__dirname, '..');
const assetDir = path.join(rootDir, 'android/app/src/main/assets');
const port = Number(process.env.PORT || process.env.DOPPEL_MOCK_PORT || 18081);
const password = process.env.DOPPEL_MOCK_PASSWORD || 'dev';
const sessionCookie = 'doppel_mock_session=1';

let snapshot = {
  permissions: {
    receiveSms: true,
    sendSms: true,
    callPhone: true,
    readPhoneState: true,
    readPhoneNumbers: true,
    sms: true,
    phone: true,
    phoneNumbers: true,
  },
  simCards: [
    {
      subscriptionId: 1,
      slotIndex: 0,
      displayName: 'SIM 1',
      carrierName: 'Mock Carrier',
      number: '+86 13800138000',
    },
    {
      subscriptionId: 2,
      slotIndex: 1,
      displayName: 'SIM 2',
      carrierName: 'Backup Carrier',
      number: '+86 13900139000',
    },
  ],
  remoteControlStatus: {
    ipAddresses: ['127.0.0.1', '192.168.4.6'],
    isRunning: true,
    port: 18080,
  },
  config: {
    forwarding: {
      selectedSmsSim: 'SIM 1 · +86 13800138000',
      smsTargets: [
        { value: '+86 13800138001' },
        { value: '+86 13800138002' },
      ],
      emailTargets: [{ value: 'notify@example.com' }],
      httpTargets: [{ value: 'https://example.com/doppel/sms' }],
      smtp: {
        host: 'smtp.example.com',
        port: '465',
        fromEmail: 'sender@example.com',
        username: 'sender@example.com',
        password: 'mock-password',
      },
    },
    commands: {
      callEnabled: true,
      smsEnabled: true,
      trustedNumbers: [
        { number: '+86 13800138003' },
        { number: '+86 13800138004' },
      ],
    },
    remoteControl: {
      enabled: true,
      port: '18080',
      password: 'dev',
      token: 'mock-token',
    },
  },
  events: [
    event('sms_received', '收到来自 +86 13800138008 的短信', {
      from: '+86 13800138008',
      to: '+86 13800138000',
      content: '这是一条用于页面调试的模拟短信。',
    }),
    event('sms_forwarded', '短信已转发到 2 个目标'),
    event('call_received', '来电：+86 13800138009', { from: '+86 13800138009' }),
    event('operation_log', 'Mock 服务已启动'),
  ],
};

function event(type, detail, extra = {}) {
  return {
    type,
    detail,
    timestamp: new Date().toISOString(),
    source: 'mock',
    ...extra,
  };
}

function readAsset(name) {
  return fs.readFileSync(path.join(assetDir, name), 'utf8');
}

function contentTypeFor(name) {
  if (name.endsWith('.js')) return 'application/javascript; charset=utf-8';
  if (name.endsWith('.css')) return 'text/css; charset=utf-8';
  if (name.endsWith('.html')) return 'text/html; charset=utf-8';
  return 'text/plain; charset=utf-8';
}

function send(res, status, contentType, body, headers = {}) {
  res.writeHead(status, {
    'Content-Type': contentType,
    'Content-Length': Buffer.byteLength(body),
    ...headers,
  });
  res.end(body);
}

function sendJson(res, status, body, headers = {}) {
  send(res, status, 'application/json; charset=utf-8', JSON.stringify(body), headers);
}

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      if (!raw) {
        resolve({});
        return;
      }
      try {
        resolve(JSON.parse(raw));
      } catch {
        resolve({});
      }
    });
  });
}

function isAuthenticated(req) {
  return req.headers.cookie?.includes(sessionCookie);
}

function mergeDeep(target, incoming) {
  for (const [key, value] of Object.entries(incoming || {})) {
    if (value === null || value === undefined) {
      continue;
    }
    if (
      value &&
      typeof value === 'object' &&
      !Array.isArray(value) &&
      target[key] &&
      typeof target[key] === 'object' &&
      !Array.isArray(target[key])
    ) {
      mergeDeep(target[key], value);
    } else {
      target[key] = value;
    }
  }
}

function updateRemoteStatusFromConfig() {
  const remote = snapshot.config.remoteControl || {};
  snapshot.remoteControlStatus.isRunning = !!remote.enabled && !!remote.password;
  snapshot.remoteControlStatus.port = snapshot.remoteControlStatus.isRunning
    ? Number(remote.port || 18080)
    : null;
}

async function route(req, res) {
  const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = url.pathname;

  if (req.method === 'GET' && pathname === '/') {
    send(res, 200, 'text/html; charset=utf-8', readAsset('remote/index.html'));
    return;
  }
  if (req.method === 'GET' && pathname.startsWith('/remote/')) {
    const assetName = pathname.replace(/^\//, '');
    send(res, 200, contentTypeFor(assetName), readAsset(assetName));
    return;
  }
  if (req.method === 'GET' && pathname === '/health') {
    sendJson(res, 200, { ok: true, service: 'doppel_remote_control_mock', port });
    return;
  }
  if (req.method === 'POST' && pathname === '/login') {
    const body = await readBody(req);
    if (body.password !== password) {
      sendJson(res, 401, { error: 'invalid_password' });
      return;
    }
    sendJson(res, 200, { ok: true }, { 'Set-Cookie': `${sessionCookie}; Path=/; HttpOnly; SameSite=Lax` });
    return;
  }
  if (req.method === 'POST' && pathname === '/logout') {
    sendJson(res, 200, { ok: true }, { 'Set-Cookie': 'doppel_mock_session=; Path=/; Max-Age=0' });
    return;
  }
  if (pathname.startsWith('/api/') && !isAuthenticated(req)) {
    sendJson(res, 401, { error: 'unauthorized' });
    return;
  }
  if (req.method === 'GET' && pathname === '/api/snapshot') {
    sendJson(res, 200, snapshot);
    return;
  }
  if (req.method === 'POST' && pathname === '/api/config') {
    const body = await readBody(req);
    mergeDeep(snapshot.config, body.config || body);
    updateRemoteStatusFromConfig();
    snapshot.events.unshift(event('operation_log', 'Mock 配置已保存'));
    sendJson(res, 200, { ok: true, snapshot });
    return;
  }
  if (req.method === 'POST' && pathname === '/api/sms/send') {
    const body = await readBody(req);
    if (!body.to || !body.message) {
      sendJson(res, 400, { ok: false, message: '请填写目标号码和短信内容' });
      return;
    }
    snapshot.events.unshift(event('sms_sent_command', `Mock 短信已提交：${body.to}`, {
      to: body.to,
      content: body.message,
      sim: body.sim || '',
    }));
    sendJson(res, 200, { ok: true, message: `Mock 已提交短信到 ${body.to}${body.sim ? `，SIM ${body.sim}` : ''}` });
    return;
  }
  if (req.method === 'POST' && pathname === '/api/call/start') {
    const body = await readBody(req);
    if (!body.number) {
      sendJson(res, 400, { ok: false, message: '请填写电话号码' });
      return;
    }
    snapshot.events.unshift(event('call_out_command', `Mock 已发起拨号：${body.number}`, {
      to: body.number,
      sim: body.sim || '',
    }));
    sendJson(res, 200, { ok: true, message: `Mock 已发起拨号 ${body.number}${body.sim ? `，SIM ${body.sim}` : ''}` });
    return;
  }

  sendJson(res, 404, { error: 'not_found' });
}

const server = http.createServer((req, res) => {
  route(req, res).catch((error) => {
    console.error(error);
    sendJson(res, 500, { error: 'internal_error', message: error.message });
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Doppel remote control mock server: http://127.0.0.1:${port}`);
  console.log(`Login password: ${password}`);
});
