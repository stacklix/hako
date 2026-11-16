'use strict';
(() => {
  const states = new Map();
  let selected = null, invoke = null, state = null, timer = null, generation = 0;
  const active = task => ['starting', 'running', 'stopping'].includes(task?.state);
  const label = task => task ? ({starting:'正在启动',running:'执行中',stopping:'正在停止',completed:'已完成',failed:'执行失败',cancelled:'已取消',timed_out:'已超时',unknown:'结果待核对'})[task.state] || task.state : '';
  const visible = value => state === value && $('workshop-commands-dialog').open && csrf && !document.hidden;
  function message(text = '') { $('workshop-command-error').textContent = text; $('workshop-command-error').hidden = !text; }
  function save() {
    if (!state || state.pending) return;
    state.name = $('workshop-command-name').value; state.command = $('workshop-command-text').value;
    state.timeout = Number($('workshop-command-timeout').value); state.background = $('workshop-command-background').checked;
  }
  function render() {
    if (!state) return;
    const value = state;
    $('workshop-command-project').textContent = value.app.name;
    $('workshop-command-name').value = value.name; $('workshop-command-text').value = value.command;
    $('workshop-command-timeout').value = value.timeout; $('workshop-command-background').checked = value.background;
    for (const id of ['name','text','timeout','background']) $('workshop-command-' + id).disabled = !!value.pending || value.busy;
    $('workshop-command-run').disabled = !!value.pending || value.busy || active(value.task);
    $('workshop-command-retry').hidden = !value.pending; $('workshop-command-retry').disabled = value.busy;
    $('workshop-command-stop').hidden = !active(value.task); $('workshop-command-stop').disabled = value.busy || value.task?.canStop === false;
    $('workshop-command-copy').hidden = !value.task; $('workshop-command-copy').disabled = !!value.pending || value.busy;
    $('workshop-command-task-state').textContent = value.task ? `${value.task.name} · ${label(value.task)}${value.task.exitCode == null ? '' : ' · 退出码 ' + value.task.exitCode}` : '';
    $('workshop-command-output').textContent = value.output;
    $('workshop-command-tasks').replaceChildren(...value.tasks.map(task => {
      const item = action(task.name + ' · ' + label(task), async () => {
        try {
          clearTimeout(timer); value.taskId = task.id; value.cursor = 0; value.output = ''; value.task = null;
          await read(value);
        } catch (e) { if (visible(value)) message(e.message); }
      }, 'quiet');
      item.setAttribute('aria-current', String(task.id === value.taskId)); return item;
    }));
  }
  async function list(value) {
    let result;
    try { result = await invoke(value.computer, 'commands.list', {applicationId:value.app.id}); }
    catch (e) {
      if (e.cause !== 'computer_offline') throw e;
      await invoke(value.computer, 'commands.open', {}, false);
      for (let attempt = 0; attempt < 12; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 500));
        if (!visible(value)) return;
        try { result = await invoke(value.computer, 'commands.list', {applicationId:value.app.id}); break; }
        catch (failure) { if (failure.cause !== 'computer_offline' || attempt === 11) throw failure; }
      }
    }
    if (!result || !visible(value)) return;
    value.tasks = result.tasks;
    if (value.pending && result.tasks.some(task => task.id === value.pending.requestId)) {
      value.taskId = value.pending.requestId; value.pending = null;
    }
    render();
  }
  async function read(value) {
    if (!visible(value) || !value.taskId) return;
    const taskId = value.taskId, version = generation;
    const page = await invoke(value.computer, 'commands.read', {taskId, cursor:value.cursor});
    if (!visible(value) || version !== generation || value.taskId !== taskId) return;
    if (!Number.isSafeInteger(page.cursor) || (page.hasMore && page.cursor === value.cursor)) throw new Error('命令日志游标未前进，请刷新历史。');
    if (page.cursor < value.cursor) return;
    if (page.cursor > value.cursor) value.output = (value.output + page.output).slice(-160000);
    value.cursor = page.cursor; value.task = page.task;
    if (value.pending?.requestId === taskId) value.pending = null;
    save();
    render();
    if (page.task.error) message(page.task.error);
    clearTimeout(timer);
    if (page.hasMore || active(page.task)) timer = setTimeout(() => read(value).catch(e => { if (visible(value)) message(e.message); }), page.hasMore ? 20 : 1000);
  }
  async function execute() {
    const value = state; if (!value || value.busy) return;
    save(); message();
    if (!value.pending) {
      if (!value.name.trim() || !value.command.trim() || new TextEncoder().encode(value.command).length > 8000 || !Number.isInteger(value.timeout) || value.timeout < 1 || value.timeout > 86400) { message('请填写名称和命令；命令最多 8000 UTF-8 字节，超时为 1–86400 秒。'); return; }
      value.pending = {requestId:crypto.randomUUID(),applicationId:value.app.id,name:value.name,command:value.command,timeoutSeconds:value.timeout,allowBackgroundProcesses:value.background};
    }
    value.busy = true; clearTimeout(timer); render();
    try {
      // Prepare the independent command worker, then submit exactly this snapshot.
      await list(value);
      if (!visible(value)) return;
      if (value.pending) {
        const request = value.pending;
        value.task = await invoke(value.computer, 'commands.start', request, false);
        value.taskId = request.requestId; value.pending = null; value.cursor = 0; value.output = '';
      }
      $('workshop-command-status').textContent = '执行器已接收命令。关闭此窗口后任务继续执行。';
      await list(value); await read(value);
    } catch (e) {
      if (['command_busy','invalid_params','invalid_request','unsupported_method','codex_application_missing','command_shell_missing','command_request_conflict','command_context_changed','command_result_large'].includes(e.cause)) value.pending = null;
      if (visible(value)) message(e.message + (value.pending ? ' 启动结果待确认，重试将沿用原请求 ID。' : ''));
    } finally { value.busy = false; if (visible(value)) render(); }
  }
  async function open() {
    if (!selected || !state) return;
    $('workshop-commands-dialog').showModal(); message(); render();
    $('workshop-command-status').textContent = '正在连接独立命令执行器…';
    const value = state;
    try {
      await list(value); if (!visible(value)) return;
      $('workshop-command-status').textContent = '在当前项目目录执行；一台电脑同时执行一条命令。';
      if (value.taskId) await read(value);
    } catch (e) { if (visible(value)) message(e.message); }
  }
  window.hakoWorkshopCommands = {
    select(view, call) {
      save(); invoke = call; selected = view;
      const key = view && JSON.stringify([view.computer,view.app.id]);
      const next = key && states.get(key);
      if (state !== next) { generation++; clearTimeout(timer); $('workshop-commands-dialog').close(); }
      if (key && !states.has(key)) states.set(key, {computer:view.computer,app:view.app,name:'',command:'',timeout:600,background:false,tasks:[],taskId:'',task:null,cursor:0,output:'',pending:null,busy:false});
      state = key ? states.get(key) : null;
      $('workshop-commands-open').disabled = !view;
    },
    reset() {
      generation++; clearTimeout(timer); states.clear(); selected = null; state = null; $('workshop-commands-dialog').close();
      for (const id of ['name','text']) $('workshop-command-' + id).value = '';
      for (const id of ['output','status','task-state','tasks']) $('workshop-command-' + id).replaceChildren();
      message();
    }
  };
  $('workshop-commands-open').addEventListener('click', open);
  $('workshop-commands-close').addEventListener('click', () => $('workshop-commands-dialog').close());
  $('workshop-commands-dialog').addEventListener('close', () => { save(); generation++; clearTimeout(timer); });
  $('workshop-command-form').addEventListener('submit', event => { event.preventDefault(); void execute(); });
  $('workshop-command-retry').addEventListener('click', execute);
  $('workshop-command-refresh').addEventListener('click', async () => { const value = state; if (!value) return; try { await list(value); if (value.taskId) await read(value); } catch (e) { if (visible(value)) message(e.message); } });
  $('workshop-command-stop').addEventListener('click', async () => {
    const value = state; if (!value?.taskId || value.busy) return;
    value.busy = true; render();
    try { value.task = await invoke(value.computer, 'commands.stop', {taskId:value.taskId}, false); await read(value); }
    catch (e) { if (visible(value)) message(e.message); }
    finally { value.busy = false; if (visible(value)) render(); }
  });
  $('workshop-command-copy').addEventListener('click', () => { if (state?.task && !state.pending) { state.name = state.task.name; state.command = state.task.command; state.background = state.task.allowBackgroundProcesses; render(); } });
  document.addEventListener('visibilitychange', () => { if (document.hidden) { generation++; clearTimeout(timer); } else if (state && visible(state) && state.taskId) void read(state).catch(e => message(e.message)); });
})();
