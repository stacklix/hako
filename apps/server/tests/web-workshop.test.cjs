const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const {webcrypto, createHash} = require('node:crypto');
const vm = require('node:vm');

async function workshop(history = [{id:'old',kind:'item',role:'assistant',text:'已有内容'}], artifacts = []) {
  const elements = new Map(), calls = [], sources = [], timers = [], observers = [], revoked = [];
  class Element {
    constructor(tag = '') { this.tag = tag; this.children = []; this.events = {}; this.attributes = {}; this.value = ''; this.hidden = false; this.checked = false; this.classList = {add() {}}; this.scrollHeight = 100; this.clientHeight = 100; this.scrollTop = 0; }
    append(...items) { this.children.push(...items); }
    replaceChildren(...items) { this.children = items; }
    setAttribute(key, value) { this.attributes[key] = value; }
    removeAttribute(key) { delete this.attributes[key]; }
    addEventListener(event, callback) { this.events[event] = callback; }
    close() { this.open = false; }
    focus() {}
    showModal() { this.open = true; }
  }
  const el = id => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
  const node = (tag, text, className) => Object.assign(new Element(tag), {textContent:text, className});
  const pc = 'PC', app = {id:'app',name:'hako',path:'C:\\Code\\hako'}, thread = 'thread-1';
  let failSend = false, requests = 0;
  const context = vm.createContext({
    console, crypto:webcrypto, Blob, Uint8Array, URL:class extends URL {
      static revokeObjectURL(url) { revoked.push(url); URL.revokeObjectURL(url); }
    }, btoa, atob, Map, Set, TextEncoder,
    IntersectionObserver:class {
      constructor(callback) { this.callback = callback; this.targets = new Set(); observers.push(this); }
      observe(target) { this.targets.add(target); }
      unobserve(target) { this.targets.delete(target); }
      disconnect() { this.targets.clear(); }
    },
    csrf:'token', $:el, node,
    action(text, fn, className) { const result = node('button', text, className); result.events.click = fn; return result; },
    document:{hidden:false, addEventListener() {}, createElement:tag => node(tag)},
    window:{addEventListener() {}, prompt:() => null},
    setInterval() {}, clearTimeout() {}, setTimeout(callback) { timers.push(callback); },
    EventSource:class {
      constructor(url) { this.url = url; sources.push(this); }
      close() { this.closed = true; }
      emit(result) { this.onmessage({data:JSON.stringify({kind:'event', result})}); }
    },
    api:async (path, method, frame, passive) => {
      if (path === 'agents') return {agents:[{id:pc,name:'Windows',online:true,modules:{workshop:{version:1}}}]};
      if (path === 'agents/PC/modules/open') return {result:{module:'workshop',version:1,path:'/ws/workshop/client'}};
      calls.push({method:frame.method, params:frame.params, passive});
      let result;
      switch (frame.method) {
        case 'applications.list': result = {applications:[app], sessions:[{id:thread,title:'修复菜单',applicationId:app.id,preview:'已有内容',state:'completed',lastSentAt:100}],nextCursor:null}; break;
        case 'models.list': result = {models:[]}; break;
        case 'history.read': result = {entries:history,artifacts,nextCursor:null}; break;
        case 'operation.read': result = {cursor:frame.params.cursor,events:[],operation:{id:frame.params.operationId,threadId:thread,state:'running'},approvals:[],artifacts:[],followups:[]}; break;
        case 'commands.list': result = {tasks:[]}; break;
        case 'commands.start': result = {id:frame.params.requestId,name:frame.params.name,state:'running'}; break;
        case 'commands.read': result = {cursor:12,output:'tests passed',hasMore:false,task:{id:frame.params.taskId,name:'运行测试',command:'go test ./...',state:'completed',exitCode:0}}; break;
        case 'turn.start':
          requests++;
          if (failSend && requests === 1) throw new Error('connection closed');
          result = {id:'operation-1',threadId:thread,state:'starting'}; break;
        default: result = {};
      }
      return {kind:'result',result};
    }
  });
  vm.runInContext(readFileSync(new URL('../internal/server/web/workshop.js', `file://${__filename}`), 'utf8'), context);
  vm.runInContext(readFileSync(new URL('../internal/server/web/workshop-commands.js', `file://${__filename}`), 'utf8'), context);
  await context.window.hakoWorkshop.start();
  await tick();
  const group = el('workshop-projects').children[0];
  const sessionButton = group.children.find(child => child.className === 'workshop-session');
  await sessionButton.events.click();
  function page(cursor, events, state = 'running') {
    return {cursor,events,operation:{id:'operation-1',threadId:thread,state},approvals:[],artifacts:[],followups:[]};
  }
  return {el,calls,sources,timers,context,group,page,revoked, failNextSend() { failSend = true; },
    revealImages() { for (const observer of observers) observer.callback([...observer.targets].map(target => ({target,isIntersecting:true}))); },
    async send(text) { el('workshop-message').value = text; el('workshop-message').events.input(); await el('workshop-compose').events.submit({preventDefault() {}}); await tick(); },
    async retry() { await el('workshop-retry').events.click(); await tick(); }};
}
function tick() { return new Promise(resolve => setImmediate(resolve)); }
function text(element) { return [element.textContent || '', ...element.children.map(text)].join(' '); }
function descendants(element, className) {
  return [...(element.className === className ? [element] : []), ...element.children.flatMap(child => descendants(child, className))];
}
async function until(predicate) {
  for (let i = 0; i < 200; i++) {
    if (predicate()) return;
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  assert.fail('Image loading did not settle');
}
function imageReply(params, data = Buffer.from('message image')) {
  const bytes = data.subarray(params.offset, params.offset + 24 * 1024);
  return {kind:'result',result:{offset:params.offset,total:data.length,nextOffset:params.offset + bytes.length,
    revision:createHash('sha256').update(data).digest('hex'),content:bytes.toString('base64')}};
}

test('prototype cards belong to their delivered messages and match complete paths instead of filenames', async () => {
  const first = {id:'a'.repeat(24),name:'build-progress',path:'C:\\Code\\hako\\work\\build.html',threadId:'thread-1'};
  const second = {id:'b'.repeat(24),name:'build-progress-second',path:'C:\\Code\\hako\\other\\build.html',threadId:'thread-1'};
  const changed = {id:'c'.repeat(24),name:'file-change',path:'C:\\Code\\hako\\work\\file-change.html',threadId:'thread-1'};
  const other = {id:'d'.repeat(24),name:'archive',path:'C:\\Code\\hako\\work\\archive.html',threadId:'thread-1'};
  const ref = (path, title) => 'visualize' + JSON.stringify({path,title}) + '';
  const w = await workshop([
    {id:'tool',kind:'fileChange',text:first.path},
    {id:'user',kind:'item',role:'user',text:second.path},
    {id:'first',kind:'item',role:'assistant',text:'第一版\n' + ref(first.path,'构建进度')},
    {id:'second',kind:'item',role:'assistant',text:'第二版\n' + ref(second.path,'另一份构建原型')},
    {id:'changed',kind:'fileChange',text:'更新 work/file-change.html'},
    {id:'basename',kind:'item',role:'assistant',text:'build.html'}
  ],[first,second,changed,other]);
  const rows = w.el('workshop-transcript').children, cards = row => descendants(row,'workshop-artifact-card');
  assert.equal(cards(rows[0]).length,0,'The delivered reply takes precedence over a file change');
  assert.equal(cards(rows[1]).length,0,'User messages do not receive prototype cards');
  assert.match(text(cards(rows[2])[0]),/构建进度.*原型 · 点击预览/);
  assert.match(text(cards(rows[3])[0]),/另一份构建原型/);
  assert.match(text(cards(rows[4])[0]),/file-change/);
  assert.equal(cards(rows[5]).length,0,'A shared basename cannot take a different prototype');
  assert.match(text(rows[6]),/会话原型.*archive/,'Unplaced files remain accessible inside the transcript');
  assert.equal(descendants(w.el('workshop-transcript'),'workshop-artifact-card').length,4);
  assert.doesNotMatch(text(w.el('workshop-transcript')),/visualize|构建进度"/);
  assert.equal(w.calls.filter(call => call.method === 'artifact.read').length,0,'Cards do not eagerly read every HTML file');
  w.context.window.hakoWorkshop.reset();
});

test('streaming prototype references render one card and hide incomplete control syntax', async () => {
  const artifact = {id:'a'.repeat(24),name:'progress',path:'C:/Code/hako/work/progress.html',threadId:'thread-1'};
  const w = await workshop(); await w.send('继续');
  const source = w.sources.at(-1), transcript = w.el('workshop-transcript');
  source.emit(w.page(10,[{kind:'delta',id:'reply',role:'assistant',text:'已完成。\nvisualize{"path":"C:/Code/hako/work/progress.html",'}]));
  assert.match(text(transcript),/已完成/);
  assert.doesNotMatch(text(transcript),/visualize|progress.html/);
  const complete = w.page(20,[{kind:'delta',id:'reply',role:'assistant',text:'"title":"构建进度"}'}]); complete.artifacts = [artifact];
  source.emit(complete);
  assert.equal(descendants(transcript,'workshop-artifact-card').length,1);
  const next = w.page(30,[{kind:'delta',id:'reply',role:'assistant',text:'\n可打开预览。'}]); next.artifacts = [artifact]; source.emit(next);
  assert.equal(descendants(transcript,'workshop-artifact-card').length,1);
  assert.match(text(transcript),/可打开预览/);
  assert.doesNotMatch(text(transcript),/visualize|"title"/);
  w.context.window.hakoWorkshop.reset();
});

test('prototype cards read the selected artifact and open the existing isolated preview', async () => {
  const artifact = {id:'a'.repeat(24),name:'progress',path:'C:/Code/hako/work/progress.html',threadId:'thread-1'};
  const w = await workshop([{id:'reply',kind:'item',role:'assistant',text:'原型：' + artifact.path}],[artifact]);
  const api = w.context.api, reads = [], html = Buffer.from('<h1>构建进度</h1><script>window.test = true</script>');
  w.context.api = async (...args) => {
    if (args[2]?.method !== 'artifact.read') return api(...args);
    reads.push(args[2].params); return imageReply(args[2].params,html);
  };
  await descendants(w.el('workshop-transcript'),'workshop-artifact-card')[0].events.click();
  assert.equal(reads.length,1);
  assert.equal(reads[0].artifactId,artifact.id);
  assert.equal(reads[0].threadId,'thread-1');
  assert.equal(w.el('workshop-preview-dialog').open,true);
  assert.equal(w.el('workshop-preview-title').textContent,'progress');
  const url = w.el('workshop-preview-frame').src;
  const document = await (await fetch(url)).text();
  assert.match(document,/Content-Security-Policy.*default-src 'none'/);
  assert.match(document,/<h1>构建进度<\/h1>/);
  w.context.window.hakoWorkshop.reset();
  assert.ok(w.revoked.includes(url));
  const index = readFileSync(new URL('../internal/server/web/index.html', `file://${__filename}`),'utf8');
  assert.match(index,/<iframe id="workshop-preview-frame"[^>]*sandbox=""/);
  assert.doesNotMatch(index,/id="workshop-artifacts"/,'The fixed strip above the composer is removed');
});

test('message images display inline, retain captions and reuse downloads across stream updates and previews', async () => {
  const w = await workshop([
    {id:'photos',kind:'item',role:'user',text:'请查看截图\n[图片 × 3]'},
    {id:'generated',kind:'imageGeneration',role:'assistant',state:'completed',text:'[图片 × 1]'},
    {id:'generating',kind:'imageGeneration',role:'assistant',state:'running',text:'正在生成'},
    {id:'literal',kind:'item',role:'user',text:'正文中的 [图片 × 1] 不代表附件'}
  ]);
  const api = w.context.api, reads = [], data = Buffer.alloc(30 * 1024, 17);
  let activeReads = 0, maximumReads = 0;
  w.context.api = async (...args) => {
    if (args[2]?.method !== 'image.read') return api(...args);
    activeReads++; maximumReads = Math.max(maximumReads, activeReads);
    await tick(); activeReads--;
    reads.push(args[2].params); return imageReply(args[2].params, data);
  };
  const transcript = w.el('workshop-transcript'), tiles = descendants(transcript, 'workshop-message-image');
  assert.equal(tiles.length, 4);
  assert.match(text(transcript), /请查看截图/);
  assert.equal(descendants(transcript.children[0], 'workshop-message-text')[0].textContent, '请查看截图');
  assert.equal(descendants(transcript.children[1], 'workshop-message-text').length, 0);
  assert.match(text(transcript), /正文中的 \[图片 × 1\] 不代表附件/);
  assert.equal(reads.length, 0, 'Images outside the visible transcript are not downloaded');
  w.revealImages();
  await until(() => tiles.every(tile => tile.children[0].src));
  for (const tile of tiles) {
    tile.children[0].events.load();
    assert.equal(tile.children[0].hidden, false);
    assert.equal(tile.children[1].hidden, true);
  }
  assert.equal(reads.length, 8, 'Each image is read in verified chunks');
  assert.equal(maximumReads, 3, 'Automatic image reads leave room for chat and progress requests');
  assert.deepEqual(reads.filter(p => p.offset === 0).map(p => [p.messageId,p.index]), [['photos',0],['photos',1],['photos',2],['generated',0]]);
  await tiles[0].events.click();
  assert.equal(w.el('workshop-preview-dialog').open, true);
  assert.equal(w.el('workshop-preview-frame').src, tiles[0].children[0].src);
  await w.send('继续');
  w.sources.at(-1).emit(w.page(10, [{kind:'delta',id:'answer',role:'assistant',text:'正在处理'}]));
  assert.equal(descendants(transcript, 'workshop-message-image')[0], tiles[0]);
  w.revealImages();
  assert.equal(reads.length, 8, 'Streaming and opening a preview reuse the loaded image');
  const urls = tiles.map(tile => tile.children[0].src);
  w.context.window.hakoWorkshop.reset();
  assert.ok(urls.every(url => w.revoked.includes(url)), 'Logout releases cached image URLs');
});

test('inline image failures offer retry without losing the message', async () => {
  const w = await workshop([{id:'photo',kind:'item',role:'user',text:'附件说明\n[图片 × 1]'}]);
  const api = w.context.api; let attempts = 0;
  w.context.api = async (...args) => {
    if (args[2]?.method !== 'image.read') return api(...args);
    attempts++;
    if (attempts === 1) throw new Error('执行电脑离线');
    return imageReply(args[2].params);
  };
  const tile = descendants(w.el('workshop-transcript'), 'workshop-message-image')[0];
  w.revealImages();
  await until(() => !tile.disabled);
  assert.match(text(tile), /图片加载失败，点击重试/);
  assert.equal(tile.title, '执行电脑离线');
  await tile.events.click();
  tile.children[0].events.load();
  assert.equal(tile.children[0].hidden, false);
  assert.match(text(w.el('workshop-transcript')), /附件说明/);
  tile.children[0].events.error();
  assert.equal(tile.children[0].hidden, true);
  assert.match(text(tile), /点击重试/);
  assert.equal(w.revoked.length, 1, 'Undecodable images release their URL');
  w.context.window.hakoWorkshop.reset();
});

test('logout discards in-flight image reads and invalid digests cannot display', async () => {
  const w = await workshop([{id:'photo',kind:'item',role:'user',text:'[图片 × 1]'}]);
  const api = w.context.api; let resolve;
  w.context.api = async (...args) => args[2]?.method === 'image.read'
    ? new Promise(done => { resolve = () => done(imageReply(args[2].params)); }) : api(...args);
  const tile = descendants(w.el('workshop-transcript'), 'workshop-message-image')[0];
  w.revealImages(); await until(() => resolve); w.context.window.hakoWorkshop.reset(); resolve(); await tick();
  assert.equal(tile.children[0].src, undefined);
  assert.equal(w.el('workshop-preview-dialog').open, false);

  const invalid = await workshop([{id:'photo',kind:'item',role:'user',text:'[图片 × 1]'}]);
  invalid.context.api = async (...args) => {
    if (args[0] === 'agents/PC/modules/open') return {result:{module:'workshop',version:1,path:'/ws/workshop/client'}};
    const reply = imageReply(args[2].params); reply.result.revision = '0'.repeat(64); return reply;
  };
  const invalidTile = descendants(invalid.el('workshop-transcript'), 'workshop-message-image')[0];
  invalid.revealImages(); await until(() => !invalidTile.disabled);
  assert.equal(invalidTile.children[0].src, undefined);
  assert.match(invalidTile.title, /文件摘要不匹配/);
  invalid.context.window.hakoWorkshop.reset();
});

test('workshop groups sessions under projects and preserves drafts when switching', async () => {
  const w = await workshop();
  assert.match(text(w.group), /hako.*＋.*修复菜单/);
  assert.doesNotMatch(text(w.group), /已有内容/);
  assert.match(text(w.el('workshop-transcript')), /已有内容/);
  w.el('workshop-message').value = '尚未发送'; w.el('workshop-message').events.input();
  await w.group.children[0].children.find(child => child.className === 'workshop-project-new').events.click({preventDefault() {}, stopPropagation() {}});
  assert.equal(w.el('workshop-message').value, '');
  await w.group.children.find(child => child.className === 'workshop-session').events.click();
  assert.equal(w.el('workshop-message').value, '尚未发送');
  assert.ok(w.calls.filter(call => call.method.endsWith('.read') || call.method.endsWith('.list')).every(call => call.passive));
});

test('uncertain workshop sends retain input and retry with the same operation request ID', async () => {
  const w = await workshop();
  w.failNextSend();
  await w.send('请修复菜单');
  assert.equal(w.el('workshop-message').value, '请修复菜单');
  assert.equal(w.el('workshop-retry').hidden, false);
  assert.equal(w.el('workshop-send').disabled, true);
  await w.retry();
  const sends = w.calls.filter(call => call.method === 'turn.start');
  assert.equal(sends.length, 2);
  assert.equal(sends[0].params.requestId, sends[1].params.requestId);
  assert.equal(sends[0].params.message, sends[1].params.message);
  assert.equal(w.el('workshop-message').value, '');
  assert.equal(w.el('workshop-retry').hidden, true);
});

test('workshop streaming merges deltas once and resumes at the applied cursor', async () => {
  const w = await workshop(); await w.send('开始');
  const source = w.sources.at(-1);
  source.emit(w.page(10, [{kind:'delta',id:'answer',role:'assistant',text:'你好'}]));
  source.emit(w.page(10, [{kind:'delta',id:'answer',role:'assistant',text:'你好'}]));
  assert.equal((text(w.el('workshop-transcript')).match(/你好/g) || []).length, 1);
  source.emit(w.page(20, [{kind:'delta',id:'answer',role:'assistant',text:'世界'}]));
  assert.match(text(w.el('workshop-transcript')), /你好世界/);
  source.onerror(); await w.timers.at(-1)();
  assert.match(w.sources.at(-1).url, /\/operation-1\/20$/);
  w.context.window.hakoWorkshop.reset();
  assert.equal(w.sources.at(-1).closed, true);
  assert.doesNotMatch(text(w.el('workshop-transcript')), /你好世界|已有内容/);
  // A late event from the old authenticated context cannot restore content.
  source.emit(w.page(30, [{kind:'item',id:'secret',role:'assistant',text:'private'}]));
  assert.doesNotMatch(text(w.el('workshop-transcript')), /private|你好世界|已有内容/);
});

test('switching the workshop computer clears the previous transcript immediately', async () => {
  const w = await workshop();
  w.el('workshop-computer').value = 'other';
  w.el('workshop-computer').events.change();
  assert.doesNotMatch(text(w.el('workshop-transcript')), /已有内容/);
  assert.equal(w.el('workshop-compose').hidden, true);
  w.context.window.hakoWorkshop.reset();
});

test('server disconnect frames reconnect from the applied cursor and clear the recovered warning', async () => {
  const w = await workshop(); await w.send('开始');
  const source = w.sources.at(-1);
  source.emit(w.page(20, [{kind:'delta',id:'answer',role:'assistant',text:'已收到'}]));
  source.onmessage({data:JSON.stringify({kind:'failure',error:{code:'workshop_disconnected',message:'代码工坊连接已中断。'}})});
  assert.equal(source.closed, true);
  assert.equal(w.el('workshop-error').textContent, '代码工坊连接已中断。');
  assert.equal(w.timers.length, 1, 'A server failure must schedule recovery without relying on onerror');
  await w.timers.at(-1)();
  const recovered = w.sources.at(-1);
  assert.notEqual(recovered, source);
  assert.match(recovered.url, /\/operation-1\/20$/);
  assert.equal(w.calls.at(-1).method, 'operation.read');
  assert.equal(w.el('workshop-error').hidden, true, 'A verified operation snapshot recovers progress before stream events arrive');
  await w.el('workshop-refresh').events.click();
  assert.equal(w.el('workshop-error').hidden, true);
  recovered.emit(w.page(30, [{kind:'delta',id:'answer',role:'assistant',text:'继续'}]));
  assert.equal(w.el('workshop-error').hidden, true);
  assert.match(text(w.el('workshop-transcript')), /已收到继续/);
  const timers = w.timers.length;
  source.onerror();
  assert.equal(w.timers.length, timers, 'An old stream cannot schedule another reconnect');
  recovered.onerror();
  const retry = w.timers.at(-1);
  w.context.window.hakoWorkshop.reset();
  const calls = w.calls.length, sources = w.sources.length;
  await retry();
  assert.equal(w.calls.length, calls, 'A queued reconnect cannot read after logout');
  assert.equal(w.sources.length, sources);
});

test('reconnection reads missed progress before subscribing from the latest cursor', async () => {
  const w = await workshop(); await w.send('开始');
  const source = w.sources.at(-1);
  source.emit(w.page(20, [{kind:'delta',id:'answer',role:'assistant',text:'已收到'}]));
  const api = w.context.api;
  w.context.api = async (...args) => args[2]?.method === 'operation.read'
    ? {kind:'result',result:w.page(40, [{kind:'delta',id:'answer',role:'assistant',text:'恢复后的进度'}])}
    : api(...args);
  source.onerror();
  await w.timers.at(-1)();
  assert.equal(w.el('workshop-error').hidden, true);
  assert.match(w.sources.at(-1).url, /\/operation-1\/40$/);
  assert.match(text(w.el('workshop-transcript')), /已收到恢复后的进度/);
  w.sources.at(-1).emit(w.page(40, [{kind:'delta',id:'answer',role:'assistant',text:'恢复后的进度'}]));
  assert.equal((text(w.el('workshop-transcript')).match(/恢复后的进度/g) || []).length, 1);
});

test('failed progress reads retain the warning and still reconnect the operation stream', async () => {
  const w = await workshop(); await w.send('开始');
  const api = w.context.api;
  w.context.api = async (...args) => args[2]?.method === 'operation.read'
    ? {kind:'failure',error:{code:'workshop_disconnected',message:'任务进度尚未恢复。'}}
    : api(...args);
  const source = w.sources.at(-1);
  source.onerror();
  await w.timers.at(-1)();
  const recovered = w.sources.at(-1);
  assert.notEqual(recovered, source);
  assert.equal(w.el('workshop-error').hidden, false);
  assert.equal(w.el('workshop-error').textContent, '任务进度尚未恢复。');
  recovered.emit(w.page(20, []));
  assert.equal(w.el('workshop-error').hidden, true);
});

test('workshop commands submit explicit execution settings and read independent task logs', async () => {
  const w = await workshop();
  await w.el('workshop-commands-open').events.click();
  w.el('workshop-command-name').value = '运行测试';
  w.el('workshop-command-text').value = 'go test ./...';
  w.el('workshop-command-timeout').value = '120';
  await w.el('workshop-command-form').events.submit({preventDefault() {}}); await tick();
  const call = w.calls.find(item => item.method === 'commands.start');
  assert.equal(call.params.command, 'go test ./...');
  assert.equal(call.params.timeoutSeconds, 120);
  assert.equal(call.params.allowBackgroundProcesses, false);
  assert.equal(call.params.applicationId, 'app');
  assert.equal(w.el('workshop-command-output').textContent, 'tests passed');
  await w.el('workshop-command-refresh').events.click();
  assert.equal(w.el('workshop-command-output').textContent, 'tests passed');
  assert.match(w.el('workshop-command-task-state').textContent, /退出码 0/);
  w.context.window.hakoWorkshop.reset();
  assert.equal(w.el('workshop-command-text').value, '');
});

test('streaming updates keep an in-progress approval answer intact', async () => {
  const w = await workshop(); await w.send('开始');
  const source = w.sources.at(-1), page = w.page(10, []);
  page.approvals = [{id:'approval',kind:'question',detail:'补充信息',questions:[{id:'q1',question:'选择实现方式',options:[]}]}];
  source.emit(page);
  const form = w.el('workshop-approvals').children[0];
  const input = form.children.find(child => child.tag === 'label').children[0];
  input.value = '正在输入的回答';
  source.emit({...page,cursor:20,events:[{kind:'delta',id:'answer',role:'assistant',text:'继续输出'}]});
  assert.equal(w.el('workshop-approvals').children[0], form);
  assert.equal(input.value, '正在输入的回答');
});
