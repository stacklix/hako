'use strict';
(() => {
  let enabled = false, epoch = 0, computer = '', computers = [], applications = [], sessions = [], models = [];
  let catalogCursor = null, catalogBusy = false, catalogVersion = 0, selected = null, stream = null, reconnect = null;
  let streamVersion = 0, previewURL = null, approvalSignature = '';
  const conversations = new Map(), collapsed = new Set();
  const running = state => ['starting', 'running', 'waiting', 'finishing', 'queued', 'steering'].includes(state);
  const stateName = state => ({starting:'正在启动', running:'执行中', waiting:'等待确认', finishing:'正在收尾', queued:'排队中', paused:'已暂停', completed:'已完成', interrupted:'已停止', failed:'执行失败', unknown:'结果待核对', idle:'就绪', sent:'已发送', steered:'已追加', cancelled:'已取消'})[state] || state || '就绪';
  const current = view => enabled && csrf && selected === view;
  const online = () => computers.some(item => item.id === computer && item.online);
  const key = (pc, app, thread) => JSON.stringify([pc, app, thread || 'new']);
  const error = message => { $('workshop-error').textContent = message; $('workshop-error').hidden = !message; };
  function connectionRecovered(view) {
    if (current(view) && view.connectionIssue && $('workshop-error').textContent === view.connectionIssue) error('');
    view.connectionIssue = '';
  }
  function button(text, callback, className = 'quiet') {
    return action(text, async () => { try { await callback(); } catch (e) { if (enabled) error(e.message); } }, className);
  }
  async function call(pc, method, params = {}, passive = true) {
    const session = csrf, generation = epoch;
    const reply = await api('workshop/calls', 'POST', {kind:'call', id:crypto.randomUUID(), computerId:pc, method, params}, passive);
    if (!enabled || csrf !== session || generation !== epoch) throw new Error('登录状态已变化，请重新打开会话。');
    if (reply.kind !== 'result') throw new Error(reply.error?.message || '工坊请求失败，请核对电脑状态。', {cause:reply.error?.code});
    return reply.result;
  }
  function viewFor(app, session) {
    const id = key(computer, app.id, session?.id);
    if (!conversations.has(id)) conversations.set(id, {
      computer, app, thread:session?.id || '', title:session?.title || '新会话', archived:$('workshop-archived').checked,
      history:[], live:new Map(), followups:[], approvals:[], artifacts:[], operation:session?.operationId || '',
      cursor:0, historyCursor:null, historyLoaded:false, loading:false, state:session?.state || 'idle',
      draft:'', attachments:[], pending:null, sending:false, questionId:'', model:'', effort:'', tier:'', permission:'auto', name:'', prompt:''
    });
    const view = conversations.get(id);
    view.archived = $('workshop-archived').checked;
    return view;
  }
  function saveDraft() {
    if (!selected) return;
    Object.assign(selected, {draft:$('workshop-message').value, model:$('workshop-model').value,
      effort:$('workshop-effort').value, tier:$('workshop-tier').value, permission:$('workshop-permission').value,
      name:$('workshop-session-name').value, prompt:$('workshop-system-prompt').value});
  }
  function stopStream() {
    streamVersion++;
    stream?.close(); stream = null;
    clearTimeout(reconnect); reconnect = null;
  }
  function drawProjects() {
    const content = [];
    for (const app of applications) {
      const all = sessions.filter(item => item.applicationId === app.id);
      const group = node('details', undefined, 'workshop-project');
      group.open = !collapsed.has(app.id);
      const summary = node('summary'); summary.append(node('strong', app.name));
      summary.append(node('span', String(all.length)));
      if (!$('workshop-archived').checked) {
        const create = node('button', '＋', 'workshop-project-new'); create.type = 'button';
        create.title = '新建会话'; create.setAttribute('aria-label', '在 ' + app.name + ' 中新建会话');
        create.disabled = !online();
        create.addEventListener('click', async event => {
          event.preventDefault(); event.stopPropagation();
          create.disabled = true;
          try { await openConversation(app); } catch (e) { if (enabled) error(e.message); }
          finally { create.disabled = !online(); }
        });
        summary.append(create);
      }
      group.addEventListener('toggle', () => { if (group.open) collapsed.delete(app.id); else collapsed.add(app.id); });
      group.append(summary);
      for (const session of all) {
        const view = conversations.get(key(computer, app.id, session.id));
        const row = button('', () => openConversation(app, session), 'workshop-session');
        row.title = session.title;
        if (view?.draft || view?.attachments.length || view?.pending) row.classList.add('has-draft');
        row.setAttribute('aria-current', String(selected?.computer === computer && selected?.thread === session.id));
        row.append(node('strong', session.title));
        const state = view?.state || session.state;
        if (running(state) || state === 'unknown' || state === 'failed') row.append(node('span', stateName(state), 'workshop-session-state'));
        group.append(row);
      }
      if (!all.length) group.append(node('p', $('workshop-archived').checked ? '没有已归档会话' : '开始这个项目的第一段会话', 'empty'));
      content.push(group);
    }
    if (!content.length) content.push(node('p', online() ? '电脑尚未发现项目。' : '选择在线电脑以读取项目。', 'empty'));
    $('workshop-projects').replaceChildren(...content);
    $('workshop-more').hidden = !catalogCursor;
  }
  async function refreshComputers() {
    const generation = epoch;
    const result = await api('workshop/computers');
    if (!enabled || generation !== epoch) return;
    computers = result.computers;
    const previous = computer;
    if (!computers.some(item => item.id === computer)) computer = computers.find(item => item.online)?.id || computers[0]?.id || '';
    $('workshop-computer').replaceChildren(...computers.map(item => {
      const option = node('option', item.name + (item.online ? ' · 在线' : ' · 离线')); option.value = item.id; return option;
    }));
    if (!computers.length) $('workshop-computer').append(node('option', '尚未登记执行电脑'));
    $('workshop-computer').value = computer;
    if (computer !== previous) { saveDraft(); stopStream(); selected = null; applications = []; sessions = []; models = []; catalogCursor = null; }
    if (!online()) {
      stopStream();
      $('workshop-catalog-status').textContent = computers.length ? '工坊离线，电脑重新连接后可继续。' : '请先在设备代理中登记电脑，并启动 Agent。';
      drawProjects(); drawConversation();
    }
  }
  async function refreshCatalog(more = false, passive = true) {
    if (!enabled || !online() || catalogBusy) return;
    catalogBusy = true;
    const pc = computer, generation = catalogVersion, archived = $('workshop-archived').checked;
    $('workshop-refresh').disabled = true;
    $('workshop-catalog-status').textContent = '正在读取项目与会话…';
    try {
      const params = {archived}; if (more && catalogCursor) params.cursor = catalogCursor;
      const result = await call(pc, 'applications.list', params, passive);
      if (pc !== computer || generation !== catalogVersion) return;
      applications = result.applications;
      sessions = more ? [...new Map([...sessions, ...result.sessions].map(item => [item.id, item])).values()] : result.sessions;
      sessions.sort((a, b) => b.lastSentAt - a.lastSentAt || a.id.localeCompare(b.id));
      catalogCursor = result.nextCursor;
      $('workshop-catalog-status').textContent = `${applications.length} 个项目 · ${sessions.length} 个会话`;
      drawProjects();
    } catch (e) {
      if (enabled && pc === computer && generation === catalogVersion) $('workshop-catalog-status').textContent = e.message;
    } finally {
      catalogBusy = false;
      $('workshop-refresh').disabled = false;
      if (enabled && generation !== catalogVersion) void refreshCatalog();
    }
  }
  async function loadModels() {
    const pc = computer;
    try {
      const result = await call(pc, 'models.list');
      if (pc !== computer) return;
      models = result.models; drawModelOptions();
    } catch (e) { if (enabled && pc === computer) error('模型列表读取失败：' + e.message); }
  }
  function options(target, items, value, fallback) {
    $(target).replaceChildren(...items.map(item => { const option = node('option', item.name); option.value = item.id; return option; }));
    $(target).value = items.some(item => item.id === value) ? value : fallback;
  }
  function drawModelOptions() {
    const modelId = selected?.model || models.find(item => item.isDefault)?.id || '';
    options('workshop-model', [{id:'',name:'Codex 默认'}, ...models], modelId, '');
    drawModelDetails();
  }
  function drawModelDetails() {
    const model = models.find(item => item.id === $('workshop-model').value);
    options('workshop-effort', [{id:'',name:'默认'}, ...(model?.reasoningEfforts || []).map(item => ({id:item.id,name:item.id}))], selected?.effort || '', '');
    options('workshop-tier', [{id:'',name:'默认'}, ...(model?.serviceTiers || [])], selected?.tier || '', '');
  }
  async function openConversation(app, session) {
    saveDraft(); stopStream(); error('');
    if (!session && $('workshop-archived').checked) {
      $('workshop-archived').checked = false; catalogVersion++; sessions = []; catalogCursor = null; void refreshCatalog(false, false);
    }
    selected = viewFor(app, session);
    const view = selected;
    drawProjects(); drawConversation();
    if (view.thread) await loadHistory(view);
    if (current(view) && view.operation) startStream(view);
  }
  async function loadHistory(view, more = false) {
    if (!view.thread || view.loading) return;
    view.loading = true;
    if (current(view)) $('workshop-history-more').disabled = true;
    try {
      const params = {threadId:view.thread}; if (more && view.historyCursor) params.cursor = view.historyCursor;
      const result = await call(view.computer, 'history.read', params);
      const loaded = view.historyLoaded;
      view.history = [...new Map((more ? [...result.entries, ...view.history] : loaded ? [...view.history, ...result.entries] : result.entries).map(entry => [entry.id, entry])).values()];
      if (more || !loaded) view.historyCursor = result.nextCursor;
      view.historyLoaded = true; view.artifacts = result.artifacts;
      if (result.operationId && view.operation !== result.operationId) {
        view.operation = result.operationId; view.cursor = 0; view.live.clear(); view.approvals = []; view.followups = [];
        if (current(view)) { stopStream(); startStream(view); }
      }
      if (current(view)) {
        if (!view.operation) connectionRecovered(view);
        drawTranscript(view, !more); drawArtifacts(view);
      }
    } catch (e) { if (current(view)) error(e.message); }
    finally { view.loading = false; if (current(view)) { $('workshop-history-more').disabled = false; $('workshop-history-more').hidden = !view.historyCursor; drawControls(view); } }
  }
  function mergedEntries(view) {
    const entries = new Map(view.history.map(entry => [entry.id, entry]));
    for (const entry of view.live.values()) {
      if (entry.replacesId) entries.delete(entry.replacesId);
      entries.set(entry.id, entry);
    }
    return [...entries.values()].filter(entry => entry.kind !== 'followup' || entry.state !== 'cancelled');
  }
  function drawTranscript(view, keepBottom = true) {
    const target = $('workshop-transcript');
    const atBottom = target.scrollHeight - target.clientHeight - target.scrollTop < 100;
    const oldHeight = target.scrollHeight, oldTop = target.scrollTop;
    const entries = mergedEntries(view);
    target.replaceChildren(...entries.map(entry => {
      const message = node('article', undefined, 'workshop-message ' + (entry.role || 'notice'));
      message.append(node('div', entry.role === 'user' ? '你' : entry.role === 'assistant' ? 'Codex' : '执行记录', 'workshop-role'));
      if (['commandExecution', 'fileChange', 'plan'].includes(entry.kind)) {
        const details = node('details'); details.append(node('summary', (entry.text || '工具执行').split('\n')[0].slice(0, 110)), node('pre', entry.text)); message.append(details);
      } else message.append(node('div', entry.text, 'workshop-message-text'));
      if (entry.truncated) message.append(node('small', '内容已截断'));
      if (entry.kind === 'imageGeneration' && entry.state === 'completed' && /\[图片 × 1\]/.test(entry.text)) message.append(button('查看图片', () => showMessageImage(view, entry, 0)));
      if (entry.role === 'user' && /\[图片 × \d\]/.test(entry.text || '')) {
        const count = Number(/\[图片 × (\d)\]/.exec(entry.text)[1]);
        for (let i = 0; i < count; i++) message.append(button('查看图片 ' + (i + 1), () => showMessageImage(view, entry, i)));
      }
      for (const question of entry.questions || []) {
        message.append(node('p', question.title));
        for (const answer of question.options) message.append(button(answer, () => chooseAnswer(view, entry, answer)));
      }
      if (entry.questions?.length) message.append(button('补充回答', () => chooseAnswer(view, entry, '')));
      if (entry.kind === 'followup') {
        message.append(node('small', stateName(entry.state)));
        const followup = view.followups.find(item => item.id === entry.id);
        if (followup && ['queued', 'paused'].includes(followup.state)) {
          message.append(button('立即追加', () => mutateFollowup(view, followup, 'steer')),
            button('编辑', () => mutateFollowup(view, followup, 'update', entry.text.replace(/\n\[图片 × \d\]$/, ''))),
            button('取消', () => mutateFollowup(view, followup, 'cancel')));
        }
      }
      return message;
    }));
    if (!entries.length) target.append(node('p', view.thread ? (view.historyLoaded ? '会话暂无消息。' : '正在读取历史消息…') : '写下第一条消息，开始这个项目的新会话。', 'empty'));
    if (keepBottom && atBottom) target.scrollTop = target.scrollHeight;
    if (!keepBottom) target.scrollTop = oldTop + target.scrollHeight - oldHeight;
    $('workshop-history-more').hidden = !view.historyCursor;
  }
  function chooseAnswer(view, entry, text) {
    if (!current(view)) return;
    view.questionId = entry.questionId || entry.id;
    $('workshop-message').value = text; saveDraft(); $('workshop-message').focus();
    $('workshop-send-status').textContent = '此消息将作为所选问题的回答发送。';
  }
  function drawAttachments(view) {
    $('workshop-attachments').replaceChildren(...view.attachments.map(file => {
      const wrapper = node('div', undefined, 'workshop-attachment'), img = node('img'); img.src = file.url; img.alt = file.name;
      const remove = button('×', () => { if (view.sending || view.pending) return; view.attachments = view.attachments.filter(item => item !== file); URL.revokeObjectURL(file.url); drawAttachments(view); });
      remove.setAttribute('aria-label', '移除 ' + file.name); wrapper.append(img, remove); return wrapper;
    }));
  }
  function drawControls(view) {
    $('workshop-state').textContent = view ? (!online() ? '执行电脑已离线，任务结果需重新连接后核对。' : stateName(view.state)) : '选择在线电脑和项目，打开会话或开始新的任务。';
    $('workshop-archive').hidden = !view?.thread;
    $('workshop-archive').textContent = view?.archived ? '恢复会话' : '归档';
    $('workshop-archive').disabled = !!view?.sending || !!view?.pending || running(view?.state);
    $('workshop-stop').hidden = !view?.operation || !running(view?.state);
    $('workshop-stop').disabled = !online();
    $('workshop-send').textContent = running(view?.state) ? '排队发送 ↑' : '发送 ↑';
    $('workshop-send').disabled = !online() || !!view?.sending || !!view?.pending || !!view?.archived || (!!view && !view.historyLoaded && !!view.thread);
    $('workshop-attach').disabled = !online() || !!view?.sending || !!view?.pending;
    $('workshop-message').readOnly = !!view?.pending;
    $('workshop-retry').hidden = !view?.pending || !!view?.sending;
    $('workshop-session-name').disabled = !!view?.thread;
    $('workshop-system-prompt').disabled = !!view?.thread;
  }
  function drawConversation() {
    const view = selected;
    window.hakoWorkshopCommands?.select(view, call);
    $('workshop-compose').hidden = !view;
    $('workshop-title').textContent = view?.title || '从一个项目开始';
    $('workshop-project-name').textContent = view?.app.name || 'CODE WORKSHOP';
    drawControls(view);
    if (!view) {
      approvalSignature = '';
      for (const id of ['workshop-transcript', 'workshop-approvals', 'workshop-artifacts', 'workshop-attachments']) $(id).replaceChildren();
      $('workshop-transcript').append(node('p', '选择左侧项目，打开会话或开始新的任务。', 'empty'));
      $('workshop-history-more').hidden = true; $('workshop-message').value = ''; error(''); return;
    }
    $('workshop-message').value = view.draft; $('workshop-permission').value = view.permission;
    $('workshop-session-name').value = view.name; $('workshop-system-prompt').value = view.prompt;
    $('workshop-send-status').textContent = view.pending ? '发送结果待确认，输入已保留。重试会沿用原请求 ID。' : '';
    drawModelOptions(); drawTranscript(view); drawAttachments(view); drawApprovals(view); drawArtifacts(view);
  }
  function applyPage(view, page) {
    if (!Number.isSafeInteger(page.cursor) || page.cursor < view.cursor) return false;
    // Cursor advancement and event application happen together. A reconnect
    // starts at the last applied byte, never at an EventSource retry URL.
    if (page.cursor > view.cursor) for (const entry of page.events) {
      const previous = view.live.get(entry.id);
      if (entry.kind === 'delta') view.live.set(entry.id, {...entry, kind:'item', text:(previous?.text || '') + entry.text});
      else view.live.set(entry.id, entry);
    }
    view.cursor = page.cursor;
    view.state = page.operation.state; view.approvals = page.approvals; view.artifacts = page.artifacts; view.followups = page.followups;
    if (page.operation.threadId && view.thread !== page.operation.threadId) {
      conversations.delete(key(view.computer, view.app.id, view.thread));
      view.thread = page.operation.threadId; view.historyLoaded = true;
      if (view.title === '新会话') view.title = view.name || view.pending?.draft?.slice(0, 80) || '新会话';
      conversations.set(key(view.computer, view.app.id, view.thread), view);
    }
    if (current(view)) {
      $('workshop-title').textContent = view.title;
      drawControls(view); drawTranscript(view); drawApprovals(view); drawArtifacts(view);
      if (page.operation.message) error(page.operation.message);
    }
    return true;
  }
  function startStream(view) {
    if (!current(view) || !view.operation || document.hidden || stream) return;
    const generation = streamVersion, operation = view.operation;
    const source = new EventSource('/consilium/api/workshop/events/' + [view.computer, operation, view.cursor].map(encodeURIComponent).join('/'));
    stream = source;
    const disconnected = message => {
      if (!current(view) || stream !== source || generation !== streamVersion || operation !== view.operation) return;
      source.close(); stream = null;
      view.connectionIssue = message;
      error(message);
      if (document.hidden) return;
      $('workshop-state').textContent = '连接中断，正在重新核对任务进度…';
      reconnect = setTimeout(async () => {
        reconnect = null;
        if (!current(view) || generation !== streamVersion || operation !== view.operation || document.hidden) return;
        try {
          await refreshComputers();
          if (!current(view) || generation !== streamVersion || operation !== view.operation || document.hidden) return;
          if (online() && await readOperation(view) && current(view) && generation === streamVersion && operation === view.operation) connectionRecovered(view);
        } catch (e) {
          if (current(view) && generation === streamVersion && operation === view.operation) {
            view.connectionIssue = e.message; error(e.message);
          }
        }
        if (current(view) && generation === streamVersion && online()) startStream(view);
      }, 3000);
    };
    source.onmessage = event => {
      if (!current(view) || stream !== source || operation !== view.operation) return;
      try {
        const frame = JSON.parse(event.data);
        if (frame.kind === 'failure') {
          if (['workshop_disconnected', 'computer_offline', 'workshop_timeout', 'stream_overflow', 'workshop_busy'].includes(frame.error?.code)) {
            disconnected(frame.error.message); return;
          }
          throw new Error(frame.error?.message || '工坊事件读取失败。');
        }
        const wasRunning = running(view.state);
        if (applyPage(view, frame.result)) connectionRecovered(view);
        if (wasRunning && !running(view.state)) { void loadHistory(view); void refreshCatalog(); }
      } catch (e) { error(e.message); source.close(); stream = null; }
    };
    source.onerror = () => disconnected('连接中断，正在重新核对任务进度…');
  }
  function drawApprovals(view) {
    const signature = JSON.stringify([view.computer, view.app.id, view.thread, view.approvals]);
    if (signature === approvalSignature) return;
    approvalSignature = signature;
    $('workshop-approvals').replaceChildren(...view.approvals.map(approval => {
      const form = node('form', undefined, 'workshop-approval');
      form.append(node('strong', approval.kind === 'question' ? 'Codex 需要补充信息' : '等待你的批准'), node('p', approval.detail));
      const answers = new Map();
      for (const question of approval.questions || []) {
        const label = node('label', question.question), input = node('input'); input.required = true; input.maxLength = 2000;
        label.append(input); form.append(label); answers.set(question.id, input);
        for (const value of question.options) form.append(button(value, () => { input.value = value; }));
      }
      const send = async decision => {
        await call(view.computer, 'approval.reply', {operationId:view.operation, approvalId:approval.id, ...(approval.kind === 'question' ? {answers:Object.fromEntries([...answers].map(([id, input]) => [id, input.value]))} : {decision})}, false);
        if (current(view)) await readOperation(view);
      };
      if (approval.kind === 'question') {
        const submit = node('button', '提交回答', 'primary'); submit.type = 'submit'; form.append(submit);
        form.addEventListener('submit', async event => { event.preventDefault(); submit.disabled = true; try { await send(); } catch (e) { if (current(view)) error(e.message); } finally { submit.disabled = false; } });
      } else form.append(button('允许本次', () => send('accept'), 'primary'), button('拒绝', () => send('decline')));
      return form;
    }));
  }
  async function readOperation(view) {
    const operation = view.operation;
    const page = await call(view.computer, 'operation.read', {operationId:operation, cursor:view.cursor});
    return view.operation === operation && applyPage(view, page);
  }
  async function mutateFollowup(view, followup, command, text) {
    if (command === 'update') {
      text = window.prompt('编辑排队消息', text);
      if (text === null) return;
      if (text.length > 4000) throw new Error('消息最多 4000 字符。');
    }
    await call(view.computer, 'message.' + command, {operationId:view.operation, messageId:followup.id, revision:followup.revision, requestId:crypto.randomUUID(), ...(command === 'update' ? {message:text} : {})}, false);
    await readOperation(view);
  }
  async function upload(view, file) {
    const data = new Uint8Array(await file.blob.arrayBuffer());
    const hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', data))].map(value => value.toString(16).padStart(2, '0')).join('');
    for (let offset = 0; offset < data.length; offset += 9 * 1024) {
      await call(view.computer, 'image.upload', {uploadId:file.id, offset, total:data.length, sha256:hash,
        content:btoa(String.fromCharCode(...data.slice(offset, offset + 9 * 1024)))}, false);
    }
    return file.id;
  }
  async function sendMessage(retry = false) {
    const view = selected;
    if (!view || view.sending || view.archived) return;
    saveDraft(); error('');
    if (!retry && view.pending) return;
    if (!view.pending) {
      if (!view.draft.trim() && !view.attachments.length) return;
      const queue = running(view.state) && !!view.operation;
      view.pending = {method:queue ? 'message.queue' : 'turn.start', requestId:crypto.randomUUID(), draft:view.draft,
        attachments:[...view.attachments], questionId:view.questionId, params:queue ? {operationId:view.operation} : {
          applicationId:view.app.id, ...(view.thread ? {threadId:view.thread} : {name:view.name, ...(view.prompt ? {systemPrompt:view.prompt} : {})}),
          model:view.model, permission:view.permission, serviceTier:view.tier}, effort:view.effort};
    }
    const pending = view.pending;
    view.sending = true; drawControls(view);
    $('workshop-send-status').textContent = '正在提交到执行电脑…';
    try {
      // Retrying uses the same upload and send IDs. Never resend automatically
      // after an uncertain write or switch to another computer.
      const imageIds = [];
      for (const file of pending.attachments) imageIds.push(await upload(view, file));
      const result = await call(view.computer, pending.method, {...pending.params, requestId:pending.requestId,
        message:pending.draft, imageIds, ...(pending.questionId ? {questionId:pending.questionId} : {}), ...(pending.effort ? {reasoningEffort:pending.effort} : {})}, false);
      if (pending.method === 'turn.start') {
        view.operation = result.id; view.cursor = 0; view.live.clear(); view.state = result.state; view.historyLoaded = true;
        if (result.threadId) {
          conversations.delete(key(view.computer, view.app.id, view.thread)); view.thread = result.threadId;
          conversations.set(key(view.computer, view.app.id, view.thread), view);
        }
        if (view.title === '新会话') view.title = view.name || pending.draft.slice(0, 80) || '图片任务';
      }
      view.pending = null; view.questionId = '';
      if (view.draft === pending.draft) view.draft = '';
      view.attachments = view.attachments.filter(file => !pending.attachments.includes(file));
      for (const file of pending.attachments) URL.revokeObjectURL(file.url);
      if (current(view)) {
        $('workshop-message').value = view.draft; drawAttachments(view);
        $('workshop-send-status').textContent = pending.method === 'message.queue' ? '消息已排队，可立即追加到当前任务。' : '电脑已接收，任务将持续执行。';
        stopStream(); startStream(view);
      }
      void refreshCatalog();
    } catch (e) {
      const rejected = ['invalid_params','codex_application_missing','codex_workspace_invalid','codex_busy','codex_image_missing','codex_image_invalid','codex_queue_full'].includes(e.cause);
      if (rejected) view.pending = null;
      if (current(view)) { error(e.message); $('workshop-send-status').textContent = rejected ? '电脑未接受本次消息，输入和附件已保留，可修改后重新发送。' : '发送结果待确认，输入和附件已保留；重试沿用原请求 ID。'; }
    } finally { view.sending = false; if (current(view)) { drawControls(view); drawProjects(); } }
  }
  async function prepareImage(file) {
    if (file.size > 30 * 1024 * 1024) throw new Error('原图不能超过 30 MB。');
    const bitmap = await createImageBitmap(file);
    try {
      const ratio = Math.min(1, 2048 / Math.max(bitmap.width, bitmap.height));
      const canvas = document.createElement('canvas'); canvas.width = Math.max(1, Math.round(bitmap.width * ratio)); canvas.height = Math.max(1, Math.round(bitmap.height * ratio));
      const context = canvas.getContext('2d'); context.fillStyle = '#ffffff'; context.fillRect(0, 0, canvas.width, canvas.height); context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      let blob;
      for (const quality of [0.85, 0.7, 0.5, 0.3]) {
        blob = await new Promise(resolve => canvas.toBlob(resolve, 'image/jpeg', quality));
        if (blob && blob.size <= 2_000_000) break;
      }
      if (!blob || blob.size > 2_000_000) throw new Error('图片压缩后仍超过 2 MB。');
      return {id:crypto.randomUUID(), name:file.name, blob, url:URL.createObjectURL(blob)};
    } finally { bitmap.close(); }
  }
  async function readFile(view, method, params, maximum) {
    let offset = 0, revision = '', total = null;
    const parts = [];
    do {
      const page = await call(view.computer, method, {...params, offset, ...(revision ? {revision} : {})});
      if (page.offset !== offset || !Number.isInteger(page.total) || page.total < 0 || page.total > maximum || !/^[0-9a-f]{64}$/.test(page.revision) ||
        (revision && revision !== page.revision) || (total !== null && total !== page.total)) throw new Error('文件校验失败，请重新打开。');
      revision = page.revision; total = page.total;
      const bytes = Uint8Array.from(atob(page.content), char => char.charCodeAt(0));
      if (page.nextOffset !== offset + bytes.length || page.nextOffset > total || (page.nextOffset === offset && offset !== total)) throw new Error('文件分块未前进。');
      parts.push(bytes); offset = page.nextOffset;
    } while (offset < total);
    const blob = new Blob(parts), hash = [...new Uint8Array(await crypto.subtle.digest('SHA-256', await blob.arrayBuffer()))].map(value => value.toString(16).padStart(2, '0')).join('');
    if (hash !== revision) throw new Error('文件摘要不匹配，请重新打开。');
    return blob;
  }
  function drawArtifacts(view) {
    $('workshop-artifacts').replaceChildren(...view.artifacts.map(artifact => button('▧ ' + artifact.name, async () => {
      const blob = await readFile(view, 'artifact.read', {threadId:view.thread, artifactId:artifact.id}, 2 * 1024 * 1024);
      if (!current(view)) return;
      const html = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; img-src data:; form-action \'none\'; base-uri \'none\'">' + await blob.text();
      if (previewURL) URL.revokeObjectURL(previewURL);
      previewURL = URL.createObjectURL(new Blob([html], {type:'text/html'}));
      $('workshop-preview-title').textContent = artifact.name; $('workshop-preview-frame').src = previewURL; $('workshop-preview-dialog').showModal();
    })));
  }
  async function showMessageImage(view, entry, index) {
    const blob = await readFile(view, 'image.read', {threadId:view.thread, messageId:entry.id, index}, 8 * 1024 * 1024);
    if (!current(view)) return;
    if (previewURL) URL.revokeObjectURL(previewURL);
    previewURL = URL.createObjectURL(new Blob([blob], {type:'image/jpeg'}));
    $('workshop-preview-title').textContent = '消息图片'; $('workshop-preview-frame').src = previewURL; $('workshop-preview-dialog').showModal();
  }
  async function refreshAll(passive = true) {
    try {
      await refreshComputers();
      if (!enabled || !online()) return;
      await refreshCatalog(false, passive);
      if (!models.length) void loadModels();
      if (selected?.thread) await loadHistory(selected);
      if (selected?.operation) startStream(selected);
      drawControls(selected);
    } catch (e) { if (enabled) error(e.message); }
  }
  window.hakoWorkshop = {
    async start() { if (enabled) return; enabled = true; epoch++; await refreshAll(); },
    reset() {
      enabled = false; epoch++; catalogVersion++; approvalSignature = ''; stopStream();
      window.hakoWorkshopCommands?.reset();
      for (const view of conversations.values()) for (const file of view.attachments) URL.revokeObjectURL(file.url);
      conversations.clear(); collapsed.clear(); selected = null; computer = ''; computers = []; applications = []; sessions = []; models = []; catalogCursor = null;
      if (previewURL) URL.revokeObjectURL(previewURL); previewURL = null;
      $('workshop-preview-dialog').close(); $('workshop-preview-frame').removeAttribute('src');
      for (const id of ['workshop-projects', 'workshop-transcript', 'workshop-approvals', 'workshop-artifacts', 'workshop-attachments']) $(id).replaceChildren();
      $('workshop-message').value = ''; error('');
      drawConversation();
    }
  };
  $('workshop-refresh').addEventListener('click', () => refreshAll(false));
  $('workshop-computer').addEventListener('change', () => {
    saveDraft(); stopStream(); catalogVersion++; computer = $('workshop-computer').value; selected = null; applications = []; sessions = []; models = []; catalogCursor = null;
    drawProjects(); drawConversation(); void refreshAll(false);
  });
  $('workshop-archived').addEventListener('change', () => { saveDraft(); stopStream(); catalogVersion++; selected = null; sessions = []; catalogCursor = null; drawConversation(); drawProjects(); void refreshCatalog(false, false); });
  $('workshop-more').addEventListener('click', () => refreshCatalog(true, false));
  $('workshop-history-more').addEventListener('click', () => { if (selected) void loadHistory(selected, true); });
  $('workshop-model').addEventListener('change', () => { if (selected) { selected.model = $('workshop-model').value; selected.effort = ''; selected.tier = ''; } drawModelDetails(); });
  $('workshop-message').addEventListener('input', saveDraft);
  $('workshop-message').addEventListener('keydown', event => { if (event.key === 'Enter' && (event.ctrlKey || event.metaKey)) { event.preventDefault(); if (!$('workshop-send').disabled) void sendMessage(); } });
  $('workshop-compose').addEventListener('submit', event => { event.preventDefault(); void sendMessage(); });
  $('workshop-retry').addEventListener('click', () => sendMessage(true));
  $('workshop-stop').addEventListener('click', async () => {
    const view = selected; if (!view?.operation) return;
    $('workshop-stop').disabled = true;
    try { await call(view.computer, 'turn.stop', {operationId:view.operation}, false); await readOperation(view); }
    catch (e) { if (current(view)) error(e.message); }
    finally { if (current(view)) drawControls(view); }
  });
  $('workshop-archive').addEventListener('click', async () => {
    const view = selected; if (!view?.thread) return;
    $('workshop-archive').disabled = true;
    try {
      await call(view.computer, 'thread.archive', {threadId:view.thread, archived:!view.archived}, false);
      view.archived = !view.archived;
      if (current(view)) { stopStream(); selected = null; drawConversation(); await refreshCatalog(false, false); }
    } catch (e) { if (current(view)) { error(e.message); drawControls(view); } }
  });
  $('workshop-attach').addEventListener('click', () => $('workshop-files').click());
  $('workshop-files').addEventListener('change', async event => {
    const view = selected, generation = epoch, files = [...event.target.files]; event.target.value = '';
    if (!view || view.sending || view.pending) return;
    try {
      if (files.length + view.attachments.length > 3) throw new Error('每条消息最多添加三张图片。');
      for (const file of files) {
        const image = await prepareImage(file);
        if (!enabled || epoch !== generation || view.pending || view.attachments.length >= 3) { URL.revokeObjectURL(image.url); continue; }
        view.attachments.push(image);
      }
      if (current(view)) drawAttachments(view);
    } catch (e) { if (current(view)) error(e.message); }
  });
  $('workshop-preview-close').addEventListener('click', () => $('workshop-preview-dialog').close());
  $('workshop-preview-dialog').addEventListener('close', () => { $('workshop-preview-frame').removeAttribute('src'); if (previewURL) URL.revokeObjectURL(previewURL); previewURL = null; });
  document.addEventListener('visibilitychange', () => { if (!enabled) return; if (document.hidden) stopStream(); else void refreshAll(); });
  window.addEventListener('pagehide', stopStream);
  setInterval(() => { if (enabled && csrf && !document.hidden) void refreshAll(); }, 20000);
})();
