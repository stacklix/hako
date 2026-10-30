'use strict';
let logsGeneration = 0, logDetailGeneration = 0, logSelection = null, logWindow = null;
function resetAccessLogs() {
  logsGeneration++; logDetailGeneration++; logSelection = null; logWindow = null;
  $('logs-hours').replaceChildren(); $('logs-rankings').replaceChildren();
  $('logs-content').hidden = true; $('logs-detail').hidden = true; $('logs-error').hidden = true;
}
function logError(error) { $('logs-error').textContent = error.message; $('logs-error').hidden = false; }
function logHourLabel(hour) {
  // Keep the server's configured wall clock and explicit offset, independent of browser timezone.
  return hour.replace('T', ' ').replace(':00:00', ':00');
}
function logTable(headers, rows) {
  const table = node('table', undefined, 'log-table'), head = node('thead'), tr = node('tr'), body = node('tbody');
  headers.forEach(title => tr.append(node('th', title))); head.append(tr);
  rows.forEach(cells => { const row = node('tr'); cells.forEach(value => { const td = node('td'); td.append(value instanceof Node ? value : document.createTextNode(String(value))); row.append(td); }); body.append(row); });
  table.append(head, body); return table;
}
function logRanking(title, values, label) {
  const box = node('section', undefined, 'log-ranking'); box.append(node('h4', title));
  if (!values.length) { box.append(node('p', '暂无数据', 'empty')); return box; }
  box.append(logTable([label, '请求数'], values.map(v => [v.value, v.count.toLocaleString('zh-CN')]))); return box;
}
function logBreakdown(title, values, firstLabel, leftTitle, leftKey, leftLabel, rightTitle, rightKey, rightLabel) {
  const section = node('section', undefined, 'log-breakdown'); section.append(node('h3', title));
  if (!values.length) { section.append(node('p', '暂无数据', 'empty')); return section; }
  values.forEach((item, index) => {
    const details = node('details'), summary = node('summary'), columns = node('div', undefined, 'log-columns');
    details.dataset.key = title + ':' + item.value;
    summary.append(node('span', `${index + 1}. ${item.value}`, 'log-value'), node('span', `${item.count.toLocaleString('zh-CN')} 次`, 'pill'));
    summary.setAttribute('aria-label', `${firstLabel} ${item.value}，${item.count} 次，展开查看排行`);
    columns.append(logRanking(leftTitle, item[leftKey], leftLabel), logRanking(rightTitle, item[rightKey], rightLabel));
    details.append(summary, columns); section.append(details);
  }); return section;
}
async function loadLogHour(item) {
  const openSections = new Set(logSelection?.domain === item.domain && logSelection?.hour === item.hour ? Array.from(document.querySelectorAll('#logs-rankings details[open]'), el => el.dataset.key) : []);
  const generation = ++logDetailGeneration; logSelection = item;
  $('logs-detail').hidden = false; $('logs-hour-title').textContent = `${item.domain} · ${item.hour ? logHourLabel(item.hour) : $('logs-range').selectedOptions[0].textContent + '汇总'}`;
  $('logs-hour-count').textContent = '正在加载排行…'; $('logs-rankings').replaceChildren();
  document.querySelectorAll('.log-hour-select').forEach(button => button.setAttribute('aria-pressed', String(button.dataset.domain === item.domain && button.dataset.hour === item.hour)));
  try {
    const params = new URLSearchParams({...logWindow, domain:item.domain});
    if (item.hour) params.set('hour', item.hour);
    const data = await api('access-logs/' + (item.hour ? 'hour' : 'rankings') + '?' + params);
    if (generation !== logDetailGeneration || !csrf) return;
    $('logs-hour-count').textContent = `访问量 ${data.visits.toLocaleString('zh-CN')} 次 · 404 ${data.notFound.toLocaleString('zh-CN')} 次`;
    const missingColumns = node('div', undefined, 'log-columns');
    missingColumns.append(logRanking('404 来源 IP · Top 10', data.notFoundIPs, 'IP'), logRanking('404 User Agent · Top 10', data.notFoundUserAgents, 'User Agent'));
    $('logs-rankings').append(
      logRanking('访问 URL · Top 10', data.topURLs, 'URL 路径'),
      logBreakdown('来源客户端 IP · Top 10', data.topClients, 'IP', '该 IP 的 User Agent · Top 10', 'userAgents', 'User Agent', '该 IP 的访问 URL · Top 10', 'urls', 'URL 路径'),
      logBreakdown('404 页面 · Top 10', data.notFoundPages, '404 页面', '该页面的来源 IP · Top 10', 'ips', 'IP', '该页面的 User Agent · Top 10', 'userAgents', 'User Agent'),
      missingColumns
    );
    document.querySelectorAll('#logs-rankings details').forEach(el => { el.open = openSections.has(el.dataset.key); });
  } catch (error) { if (generation === logDetailGeneration && csrf) { $('logs-hour-count').textContent = '排行加载失败，请点击该行重试。'; logError(error); } }
}
async function refreshAccessLogs() {
  if (!csrf) return;
  const generation = ++logsGeneration;
  // Invalidate an older detail response while filters are changing.
  logDetailGeneration++;
  $('logs-refresh').disabled = true; $('logs-error').hidden = true;
  try {
    const params = new URLSearchParams({rangeHours:$('logs-range').value});
    if ($('logs-domain').value) params.set('domain', $('logs-domain').value);
    const data = await api('access-logs?' + params);
    if (generation !== logsGeneration || !csrf) return;
    const status = data.status;
    $('logs-content').hidden = !status.enabled;
    if (!status.enabled) { $('logs-status').textContent = '尚未启用。请在服务器配置 accessLogs.directory，并将 Caddy 日志目录挂载到服务端容器后重启。'; return; }
    $('logs-status').textContent = `${status.timezone} · 每 ${status.scanIntervalSeconds} 秒扫描 · 保留 ${status.retentionDays} 天 · ${status.scanning ? '正在扫描' : status.lastScan ? '最近扫描 ' + date(status.lastScan) : '等待首次扫描'} · ${status.files} 个文件 · 本轮新增 ${status.imported} 条 / 跳过无效 ${status.skipped} 条`;
    if (status.error) logError(new Error('日志扫描异常：' + status.error));
    logWindow = {rangeHours:String(data.rangeHours), from:data.from, to:data.to};
    $('logs-range').value = String(data.rangeHours);
    $('logs-window').textContent = `查询区间 ${logHourLabel(data.from)} — ${logHourLabel(data.to)}`;
    const selectedDomain = $('logs-domain').value;
    $('logs-domain').replaceChildren(node('option', '全部域名'));
    $('logs-domain').firstChild.value = '';
    data.domains.forEach(domain => { const option = node('option', domain); option.value = domain; $('logs-domain').append(option); });
    if (selectedDomain && !data.domains.includes(selectedDomain)) { const option = node('option', selectedDomain); option.value = selectedDomain; $('logs-domain').append(option); }
    $('logs-domain').value = selectedDomain;
    $('logs-hours').replaceChildren();
    if (data.truncated) $('logs-hours').append(node('p', '当前仅显示最近 2000 条小时记录，请选择域名缩小范围。', 'muted'));
    const items = [...data.totals.map(item => ({...item,hour:''})), ...data.hours];
    if (!items.length) { empty('logs-hours', '所选时间区间和域名暂无访问记录。'); $('logs-detail').hidden = true; logSelection = null; return; }
    $('logs-hours').append(logTable(['域名 / 时间（点击查看）', '访问量', '404'], items.map(item => {
      const button = node('button', `${item.domain} · ${item.hour ? logHourLabel(item.hour) : '区间合计'}`, 'log-hour-select quiet');
      button.type = 'button'; button.dataset.domain = item.domain; button.dataset.hour = item.hour;
      button.addEventListener('click', () => loadLogHour(item));
      return [button, item.visits.toLocaleString('zh-CN'), item.notFound.toLocaleString('zh-CN')];
    })));
    const selected = items.find(item => item.domain === logSelection?.domain && item.hour === logSelection?.hour) || items[0];
    await loadLogHour(selected);
  } catch (error) { if (generation === logsGeneration && csrf) { $('logs-hours').replaceChildren(); $('logs-detail').hidden = true; logError(error); } }
  finally { if (generation === logsGeneration) $('logs-refresh').disabled = false; }
}
$('logs-refresh').addEventListener('click', refreshAccessLogs);
$('logs-range').addEventListener('change', () => { logSelection = null; refreshAccessLogs(); });
$('logs-domain').addEventListener('change', () => { logSelection = null; refreshAccessLogs(); });
setInterval(() => { if (!document.hidden && csrf) refreshAccessLogs(); }, 60000);
