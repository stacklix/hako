import { resolve } from 'node:path';
import { createApp } from './app.js';
import { apnsProvider } from './apns.js';

const secret = process.env.HAKO_NOTIFICATION_WORKER_TOKEN;
const dataDir = process.env.HAKO_NOTIFICATION_DATA_DIR;
if (!secret || !/^[A-Za-z0-9_-]{43}$/.test(secret) || !dataDir) {
  throw new Error('Notification engine must be started by Hako');
}
const trustedConsoles: string[] = JSON.parse(process.env.HAKO_NOTIFICATION_CONSOLES || '[]');
const { app } = await createApp({
  dataDir: resolve(dataDir), secret, trustedConsoles,
  encryptionKey: process.env.HAKO_NOTIFICATION_ENCRYPTION_KEY,
  apns: apnsProvider(process.env), logger: { stream: process.stderr },
  webDir: resolve(import.meta.dirname, '../web'),
});
await app.listen({ host: '127.0.0.1', port: 0 });
const address = app.server.address();
if (!address || typeof address === 'string') throw new Error('Notification engine did not start');
process.stdout.write(String(address.port) + '\n');
let closing = false;
async function close() {
  if (closing) return;
  closing = true;
  await app.close();
  process.exit(0);
}
process.stdin.resume();
process.stdin.on('end', close);
process.on('SIGTERM', close);
process.on('SIGINT', close);
