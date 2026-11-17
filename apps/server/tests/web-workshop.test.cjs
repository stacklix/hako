const assert = require('node:assert/strict');
const {test} = require('node:test');
const {readFileSync} = require('node:fs');
const {webcrypto} = require('node:crypto');
const vm = require('node:vm');

async function workshop() {
  const elements = new Map(), calls = [], sources = [], timers = [];
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
    console, crypto:webcrypto, Blob, Uint8Array, URL, btoa, atob, Map, Set, TextEncoder,
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
      if (path === 'workshop/computers') return {computers:[{id:pc,name:'Windows',online:true}]};
      calls.push({method:frame.method, params:frame.params, passive});
      let result;
      switch (frame.method) {
        case 'applications.list': result = {applications:[app], sessions:[{id:thread,title:'修复菜单',applicationId:app.id,preview:'已有内容',state:'completed',lastSentAt:100}],nextCursor:null}; break;
        case 'models.list': result = {models:[]}; break;
        case 'history.read': result = {entries:[{id:'old',kind:'item',role:'assistant',text:'已有内容'}],artifacts:[],nextCursor:null}; break;
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
  return {el,calls,sources,timers,context,group,page, failNextSend() { failSend = true; },
    async send(text) { el('workshop-message').value = text; el('workshop-message').events.input(); await el('workshop-compose').events.submit({preventDefault() {}}); await tick(); },
    async retry() { await el('workshop-retry').events.click(); await tick(); }};
}
function tick() { return new Promise(resolve => setImmediate(resolve)); }
function text(element) { return [element.textContent || '', ...element.children.map(text)].join(' '); }

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
