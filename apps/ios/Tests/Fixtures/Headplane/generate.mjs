// Usage: node generate.mjs /absolute/path/react-router/dist/development/vendor/turbo-stream-v2/flatten.js
// Encoder: official react-router@8.4.0 (Headplane v0.8.2), bundled turbo-stream v2. No production credentials.
import { pathToFileURL } from 'node:url';
import { writeFile } from 'node:fs/promises';
const { flatten } = await import(pathToFileURL(process.argv[2]));
const user = { id: '1', name: 'li', email: 'li@example.test' };
const router = { id: '2', name: 'router', givenName: 'home-router', ipAddresses: ['100.64.0.2', 'fd7a:115c:a1e0::2'], online: true, expired: false, expiry: '0001-01-01T00:00:00Z', lastSeen: '2026-11-03T02:00:00Z', user, tags: ['tag:router'], availableRoutes: ['192.168.1.0/24', '0.0.0.0/0', '::/0'], approvedRoutes: ['192.168.1.0/24'], hostInfo: { OS: 'linux', IPNVersion: '1.90.0' } };
const laptop = { ...router, id: '3', givenName: 'macbook', online: false, availableRoutes: [], approvedRoutes: [], hostInfo: undefined, tags: [] };
const machines = { nodes: [router, laptop], populatedNodes: [router, laptop], users: [user], writable: true, preAuth: true, agent: undefined };
const policy = '{\n  // Keep this comment\n  "groups": {"group:home": ["li",],},\n  "acls": [{"action":"accept","src":["*"],"dst":["*:22"],},],\n}';
class ResponseError { constructor(status, data) { this.status = status; this.data = data; } }
class Redirect { constructor(url) { this.url = url; } }
const fixtures = {
  machines: { 'routes/machines/overview': { data: machines } },
  policy: { 'routes/acls/overview': { data: { policy, writable: true, access: true } } },
  keys: { 'routes/settings/auth-keys/overview': { data: { users: [user], access: true, missing: [], keys: [{user, preAuthKeys: [{id: '10', key: 'test-only-preauth-key', user, expiration: '2099-01-01T00:00:00Z', reusable: true, used: true}]}] } } },
  agent: { 'routes/settings/agent': { data: { enabled: true, syncedAt: '2026-11-04T00:00:00Z', nodeCount: 3, error: undefined, authUrl: undefined } } },
  agentError: { 'routes/settings/agent': { data: { enabled: true, syncedAt: '2026-11-04T00:00:00Z', nodeCount: 3, error: 'Headscale is unavailable', authUrl: undefined } } },
  agentPending: { 'routes/settings/agent': { data: { enabled: true, syncedAt: null, nodeCount: 0, error: undefined, authUrl: 'https://headscale.example.test/register/test-only' } } },
  agentDisabled: { 'routes/settings/agent': { data: { enabled: false, reason: 'Agent is not configured' } } },
  dnsServerError: { 'routes/dns/overview': { error: new Error('Unexpected Server Error') } },
  action: {data: {success: true}},
  created: {data: {success: true, key: 'test-only-new-key'}},
  expired: {data: 'Pre-auth key expired'},
  delete: new Redirect('/admin/machines'),
  login: new Redirect('/admin/login'),
  denied: {'routes/acls/overview': {error: new ResponseError(403, 'Permission denied')}},
  specials: {date: new Date('2026-11-03T00:00:00Z'), absent: undefined, nil: null, set: new Set(['tag:router']), large: 9007199254740993n},
};
for (const [name, input] of Object.entries(fixtures)) {
  const context = {deferred: {}, index: 0, indices: new Map(), stringified: [], plugins: [v => {
    if (v instanceof ResponseError) return ['ErrorResponse', v.data, v.status, 'Forbidden'];
    if (v instanceof Error) return ['SanitizedError', v.name, v.message, undefined];
    if (v instanceof Redirect) return ['SingleFetchRedirect', {redirect: v.url, status: 302, revalidate: false, reload: false, replace: false}];
  }], postPlugins: [], signal: new AbortController().signal};
  await flatten.call(context, input);
  await writeFile(new URL(name + '.data', import.meta.url), '[' + context.stringified.join(',') + ']\n');
}
