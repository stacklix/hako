// Prepare an executable copy of the official Headplane v0.8.2 OIDC service.
// Only host imports and the build-time prefix are replaced; protocol logic is unchanged.
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {resolve, join} from 'node:path';
import {createHash} from 'node:crypto';
import {stripTypeScriptTypes} from 'node:module';
const root = resolve(process.argv[2] || '../../build/oidc-validation/headplane-runtime');
await mkdir(root, {recursive:true});
const source = process.argv[3] ? await readFile(process.argv[3], 'utf8') : await (await fetch('https://raw.githubusercontent.com/tale/headplane/v0.8.2/app/server/oidc/provider.ts')).text();
if (createHash('sha256').update(source).digest('hex') !== 'b8fda14d0f71a995d68907ed5b5eceec1e506916986d99737fa19accd79d3b62') throw Error('Official provider source hash mismatch');
const prepared = source
  .replace('import { type Result, err, ok } from "~/server/result";', 'const ok = value => ({ok:true,value}); const err = error => ({ok:false,error});')
  .replace('import log from "~/utils/log";', 'const log = {debug(){},warn(){},error(){}};');
await writeFile(join(root,'provider.mjs'), 'const __PREFIX__="/admin";\n' + stripTypeScriptTypes(prepared));
await writeFile(join(root,'runner.mjs'), `import {createInterface} from 'node:readline';
import {createOidcService} from './provider.mjs';
const lines=createInterface({input:process.stdin})[Symbol.asyncIterator]();
const config=JSON.parse((await lines.next()).value);
const service=createOidcService(config);
const flow=await service.startFlow();
if(!flow.ok) throw Error(flow.error.code);
console.log(JSON.stringify({url:flow.value.url}));
const callback=new URL((await lines.next()).value);
const result=await service.handleCallback(callback.searchParams,flow.value.flowState);
if(!result.ok) throw Error(result.error.code);
const {subject,name,username,email}=result.value;
console.log(JSON.stringify({subject,name,username,email}));
process.exit(0);
`);
console.log('Prepared official provider; install jose@6.2.12 in ' + root);
