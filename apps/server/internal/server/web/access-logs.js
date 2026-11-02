'use strict';
let logsGeneration = 0, logDetailGeneration = 0, logSelection = null, logWindow = null;
function resetAccessLogs() {
  logsGeneration++; logDetailGeneration++; logSelection = null; logWindow = null;
  $('logs-empty').replaceChildren(); $('logs-rankings').replaceChildren();
  $('logs-content').hidden = true; $('logs-detail').hidden = true; $('logs-error').hidden = true;
}
function logError(error) { $('logs-error').textContent = error.message; $('logs-error').hidden = false; }
function logTimeLabel(hour) {
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
function logBreakdown(title, values, firstLabel, leftTitle, leftKey, leftLabel, rightTitle, rightKey, rightLabel, extraTitle, extraKey, extraLabel) {
  const section = node('section', undefined, 'log-breakdown'); section.append(node('h3', title));
  if (!values.length) { section.append(node('p', '暂无数据', 'empty')); return section; }
  values.forEach((item, index) => {
    const details = node('details'), summary = node('summary'), columns = node('div', undefined, 'log-columns');
    details.dataset.key = title + ':' + item.value;
    summary.append(node('span', `${index + 1}. ${item.value}`, 'log-value'), node('span', `${item.count.toLocaleString('zh-CN')} 次`, 'pill'));
    summary.setAttribute('aria-label', `${firstLabel} ${item.value}，${item.count} 次，展开查看排行`);
    columns.append(logRanking(leftTitle, item[leftKey], leftLabel), logRanking(rightTitle, item[rightKey], rightLabel));
    if (extraKey) columns.append(logRanking(extraTitle, item[extraKey], extraLabel));
    details.append(summary, columns); section.append(details);
  }); return section;
}
async function loadLogDomain(item) {
  const openSections = new Set(logSelection?.domain === item.domain ? Array.from(document.querySelectorAll('#logs-rankings details[open]'), el => el.dataset.key) : []);
  const generation = ++logDetailGeneration; logSelection = item;
  $('logs-detail').hidden = false; $('logs-domain-title').textContent = item.domain;
  $('logs-domain-count').textContent = '正在加载排行…'; $('logs-rankings').replaceChildren();
  try {
    const params = new URLSearchParams({...logWindow, domain:item.domain});
    const data = await api('access-logs/rankings?' + params);
    if (generation !== logDetailGeneration || !csrf) return;
    $('logs-domain-count').textContent = `访问量 ${data.visits.toLocaleString('zh-CN')} 次 · 4xx ${data.notFound.toLocaleString('zh-CN')} 次`;
    const missingColumns = node('div', undefined, 'log-columns');
    missingColumns.append(logRanking('4xx 来源 IP · Top 10', data.notFoundIPs, 'IP'), logRanking('4xx User Agent · Top 10', data.notFoundUserAgents, 'User Agent'));
    $('logs-rankings').append(
      logRanking('访问 URL · Top 10', data.topURLs, 'URL 路径'),
      logRanking('非 4xx URL · Top 10', data.non4xxURLs, 'URL 路径'),
      logBreakdown('来源客户端 IP · Top 10', data.topClients, 'IP', '非 4xx URL · Top 10', 'non4xxURLs', 'URL 路径', '4xx URL · Top 10', 'clientErrorURLs', 'URL 路径', '该 IP 的 User Agent · Top 10', 'userAgents', 'User Agent'),
      logBreakdown('4xx 页面 · Top 10', data.notFoundPages, '4xx 页面', '该页面的来源 IP · Top 10', 'ips', 'IP', '该页面的 User Agent · Top 10', 'userAgents', 'User Agent'),
      missingColumns
    );
    document.querySelectorAll('#logs-rankings details').forEach(el => { el.open = openSections.has(el.dataset.key); });
  } catch (error) { if (generation === logDetailGeneration && csrf) { $('logs-domain-count').textContent = '排行加载失败，请刷新统计重试。'; logError(error); } }
}
async function refreshAccessLogs() {
  if (currentPage !== 'access-logs' || !csrf) return;
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
    $('logs-window').textContent = `查询区间 ${logTimeLabel(data.from)} — ${logTimeLabel(data.to)}`;
    const selectedDomain = $('logs-domain').value;
    $('logs-domain').replaceChildren(node('option', '全部域名'));
    $('logs-domain').firstChild.value = '';
    data.domains.forEach(domain => { const option = node('option', domain); option.value = domain; $('logs-domain').append(option); });
    if (selectedDomain && !data.domains.includes(selectedDomain)) { const option = node('option', selectedDomain); option.value = selectedDomain; $('logs-domain').append(option); }
    $('logs-domain').value = selectedDomain;
    $('logs-empty').replaceChildren();
    const items = data.totals;
    if (!items.length) { empty('logs-empty', '所选时间区间和域名暂无访问记录。'); $('logs-detail').hidden = true; logSelection = null; return; }
    const selected = items.find(item => item.domain === logSelection?.domain) || items[0];
    await loadLogDomain(selected);
  } catch (error) { if (generation === logsGeneration && csrf) { $('logs-empty').replaceChildren(); $('logs-detail').hidden = true; logError(error); } }
  finally { if (generation === logsGeneration) $('logs-refresh').disabled = false; }
}
$('logs-refresh').addEventListener('click', refreshAccessLogs);
$('logs-range').addEventListener('change', () => { logSelection = null; refreshAccessLogs(); });
$('logs-domain').addEventListener('change', () => { logSelection = null; refreshAccessLogs(); });
setInterval(() => { if (!document.hidden && csrf) refreshAccessLogs(); }, 60000);
