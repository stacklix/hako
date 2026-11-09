import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { connect, type ClientHttp2Session } from 'node:http2';
import type { PushDevice } from '../shared/types.js';

export interface ApnsRequest {
  id: string;
  environment: PushDevice['environment'];
  token: string;
  payload: string;
  expiresAt: number;
}
export interface ApnsResponse { status: number; reason?: string; timestamp?: number }
export interface ApnsProvider {
  send(request: ApnsRequest): Promise<ApnsResponse>;
  close(): void;
}

export function apnsProvider(env: NodeJS.ProcessEnv): ApnsProvider | undefined {
  const { APNS_TEAM_ID: teamId, APNS_KEY_ID: keyId, APNS_BUNDLE_ID: topic, APNS_KEY_FILE: keyFile } = env;
  if (!teamId && !keyId && !topic && !keyFile) return;
  if (!teamId || !keyId || !topic || !keyFile || !/^[A-Z0-9]{10}$/.test(teamId) ||
      !/^[A-Z0-9]{10}$/.test(keyId) || !/^[a-zA-Z0-9.-]+$/.test(topic)) {
    throw new Error('请检查 APNS_TEAM_ID、APNS_KEY_ID、APNS_BUNDLE_ID 和 APNS_KEY_FILE');
  }
  let key;
  try {
    key = createPrivateKey(readFileSync(keyFile));
    if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error();
  } catch {
    throw new Error('APNS_KEY_FILE 必须指向可读取的 Apple APNs P-256 私钥');
  }
  const privateKey = key;
  const sessions = new Map<PushDevice['environment'], ClientHttp2Session>();
  let jwt: { value: string; issuedAt: number } | undefined;
  const base64 = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url');
  function authorization() {
    const now = Math.floor(Date.now() / 1000);
    if (!jwt || now - jwt.issuedAt >= 45 * 60) {
      const claims = `${base64({ alg: 'ES256', kid: keyId })}.${base64({ iss: teamId, iat: now })}`;
      const signature = sign('sha256', Buffer.from(claims), { key: privateKey, dsaEncoding: 'ieee-p1363' });
      jwt = { value: `${claims}.${signature.toString('base64url')}`, issuedAt: now };
    }
    return `bearer ${jwt.value}`;
  }
  return {
    async send(request) {
      let session = sessions.get(request.environment);
      if (!session || session.closed || session.destroyed) {
        const host = request.environment === 'sandbox' ? 'api.sandbox.push.apple.com' : 'api.push.apple.com';
        session = connect(`https://${host}`, { minVersion: 'TLSv1.2' });
        sessions.set(request.environment, session);
        session.on('error', () => { /* stream errors are handled below */ });
        const current = session;
        session.on('close', () => {
          if (sessions.get(request.environment) === current) sessions.delete(request.environment);
        });
        session.on('goaway', () => current.close());
      }
      const stream = session.request({
        ':method': 'POST', ':path': `/3/device/${request.token}`,
        authorization: authorization(), 'content-type': 'application/json',
        'apns-topic': topic, 'apns-push-type': 'alert', 'apns-id': request.id,
        'apns-expiration': String(Math.floor(request.expiresAt / 1000)),
      }, { signal: AbortSignal.timeout(15_000) });
      return await new Promise<ApnsResponse>((resolve, reject) => {
        let status: number | undefined, body = '';
        stream.setEncoding('utf8');
        stream.on('response', headers => { status = headers[':status']; });
        stream.on('data', chunk => { if (body.length < 4096) body += chunk; });
        stream.on('error', reject);
        stream.on('close', () => reject(new Error('APNs stream closed')));
        stream.on('end', () => {
          if (!status) { reject(new Error('APNs response missing')); return; }
          let detail: { reason?: unknown; timestamp?: unknown } = {};
          try { detail = JSON.parse(body) ?? {}; } catch { /* status is sufficient */ }
          resolve({ status, reason: typeof detail.reason === 'string' ? detail.reason : undefined,
            timestamp: typeof detail.timestamp === 'number' ? detail.timestamp : undefined });
        });
        stream.end(request.payload);
      });
    },
    close() {
      for (const session of sessions.values()) session.destroy();
      sessions.clear();
    },
  };
}
