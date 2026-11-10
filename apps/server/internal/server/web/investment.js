'use strict';

const investmentAccountTypes = {
  securities: '证券账户', fund: '基金账户', futures: '期货账户', wealth: '理财账户',
  deposits: '存款账户', crypto: '加密货币账户', insurance: '保险账户'
};
const investmentAssetTypes = {
  stock: '股票', etf: 'ETF', fund: '基金', future: '期货', crypto: '现货', crypto_contract: '合约',
  wealth: '理财产品', insurance: '保险', deposit: '定期存款', certificate: '大额存单'
};
const investmentEventTypes = {
  deposit: '转入', withdrawal: '提取', adjustment: '余额调整', opening: '首次录入', buy: '买入', sell: '卖出',
  transfer_in: '划入', transfer_out: '划出', income: '收益', dividend: '现金分红', bonus_shares: '送股',
  staking_reward: '质押奖励', spot_adjustment: '现货余额调整', derivative_margin: '保证金划转',
  derivative_funding: '资金费', derivative_settlement: '实际结算', derivative_trade: '合约交易'
};
const investmentCategories = {cash: '流动资金', investments: '投资理财', fixed: '固定资产', receivables: '应收款', liabilities: '负债'};
const investmentPeriods = [['近1周', 0, 7], ['近1月', 1], ['近3月', 3], ['近半年', 6], ['近1年', 12]];
const investmentSnapshotStatus = {complete: '已保存', partial: '部分数据缺失', missing: '缺少估值数据'};
const investmentNumber = new Intl.NumberFormat('zh-CN', {maximumFractionDigits: 8});
const investmentPercent = new Intl.NumberFormat('zh-CN', {style: 'percent', maximumFractionDigits: 2, signDisplay: 'exceptZero'});
const investmentRatio = new Intl.NumberFormat('zh-CN', {style: 'percent', maximumFractionDigits: 2});
const investmentCurrencies = Object.fromEntries(['CNY', 'USD', 'HKD'].map(currency => [currency,
  new Intl.NumberFormat('zh-CN', {style: 'currency', currency})]));

let investmentRequest = 0, investmentSelectedAccount = '', investmentMonth = '', investmentChartRange = 'all';

function resetInvestment() {
  investmentRequest++;
  investmentSelectedAccount = investmentMonth = '';
  investmentChartRange = 'all';
  $('investment-refresh').disabled = false;
  $('investment-status').textContent = '';
  $('investment-content').replaceChildren();
}

async function refreshInvestment() {
  if (!csrf || $('investment-refresh').disabled) return;
  const request = ++investmentRequest;
  const status = $('investment-status');
  $('investment-refresh').disabled = true;
  status.textContent = '正在读取投资账本…';
  try {
    const data = await api('investment/' + investmentPage);
    if (request !== investmentRequest) return;
    const render = {overview: investmentOverview, accounts: investmentAccounts,
      watchlist: investmentWatchlist, 'balance-sheet': investmentBalanceSheet}[investmentPage];
    $('investment-content').replaceChildren(...render(data.tables));
    const snapshotStatus = data.dirtyFrom ? ` · ${data.dirtyFrom} 起的历史快照待 iOS 重算` : '';
    status.textContent = '只读 · 显示服务端已保存的数据' + snapshotStatus;
  } catch (error) {
    if (request === investmentRequest) status.textContent = '读取投资账本失败。' + error.message;
  } finally {
    if (request === investmentRequest) $('investment-refresh').disabled = false;
  }
}
$('investment-refresh').addEventListener('click', refreshInvestment);

function investmentMoney(value, currency = 'CNY') {
  if (value == null) return '—';
  return investmentCurrencies[currency]?.format(value) ?? investmentNumber.format(value) + ' ' + currency;
}

// Ledger decimals arrive as strings. Keep displayed sums exact before currency formatting.
function investmentSum(...values) {
  const parts = values.map(value => String(value).split('.'));
  const scale = Math.max(0, ...parts.map(([, fraction = '']) => fraction.length));
  const total = parts.reduce((sum, [whole, fraction = '']) => sum + BigInt(whole + fraction.padEnd(scale, '0')), 0n);
  const digits = String(total < 0n ? -total : total).padStart(scale + 1, '0');
  return (total < 0n ? '-' : '') + (scale ? digits.slice(0, -scale) + '.' + digits.slice(-scale) : digits);
}

function investmentBefore(day, months, days = 0) {
  const value = new Date(day + 'T00:00:00Z');
  if (months) {
    const date = value.getUTCDate();
    value.setUTCDate(1);
    value.setUTCMonth(value.getUTCMonth() - months);
    const last = new Date(Date.UTC(value.getUTCFullYear(), value.getUTCMonth() + 1, 0)).getUTCDate();
    value.setUTCDate(Math.min(date, last));
  } else value.setUTCDate(value.getUTCDate() - days);
  return value.toISOString().slice(0, 10);
}

function investmentCard(title, ...children) {
  const card = node('article', undefined, 'card investment-card');
  card.append(node('h2', title), ...children);
  return card;
}

function investmentMetrics(metrics) {
  const grid = node('div', undefined, 'investment-metrics');
  for (const [label, value] of metrics) {
    const item = node('div', undefined, 'investment-metric');
    item.append(node('span', label, 'muted'), node('strong', value));
    grid.append(item);
  }
  return grid;
}

function investmentTable(headers, rows, emptyText = '暂无记录。') {
  if (!rows.length) return node('p', emptyText, 'empty');
  const wrapper = node('div', undefined, 'investment-table-wrap');
  const table = node('table', undefined, 'investment-table');
  const head = node('thead'), heading = node('tr'), body = node('tbody');
  for (const label of headers) {
    const cell = node('th', label);
    cell.scope = 'col';
    heading.append(cell);
  }
  head.append(heading);
  table.append(head, body);
  wrapper.append(table);
  const more = node('button', '显示更多', 'quiet investment-more');
  more.type = 'button';
  let offset = 0;
  function appendRows() {
    for (const values of rows.slice(offset, offset + 100)) {
      const row = node('tr');
      for (const value of values) row.append(node('td', value ?? '—'));
      body.append(row);
    }
    offset += 100;
    more.hidden = offset >= rows.length;
  }
  more.addEventListener('click', appendRows);
  appendRows();
  wrapper.append(more);
  return wrapper;
}

function investmentByOrder(rows = []) {
  return [...rows].sort((a, b) => Number(a.sort_order) - Number(b.sort_order));
}

function investmentByDate(rows = [], field = 'snapshot_date') {
  return [...rows].sort((a, b) => a[field].localeCompare(b[field]));
}

const investmentSVG = 'http://www.w3.org/2000/svg';
function investmentGraphic(tag, attributes) {
  const element = document.createElementNS(investmentSVG, tag);
  for (const [name, value] of Object.entries(attributes)) element.setAttribute(name, value);
  return element;
}

function investmentLineChart(points, series, label, includesZero = false) {
  const values = points.flatMap(point => series.flatMap(([key]) => point[key] == null ? [] : [Number(point[key])]));
  if (!values.length) return node('p', '暂无可绘制的资产快照。', 'empty');
  const lo = values.reduce((min, value) => Math.min(min, value), includesZero ? 0 : Infinity);
  const hi = values.reduce((max, value) => Math.max(max, value), includesZero ? 0 : -Infinity);
  const svg = investmentGraphic('svg', {viewBox: '0 0 640 150', role: 'img',
    'aria-label': `${label}，最低 ${investmentMoney(lo)}，最高 ${investmentMoney(hi)}`});
  const firstTime = Date.parse(points[0].day), lastTime = Date.parse(points.at(-1).day);
  const y = value => hi === lo ? 75 : 140 - 130 * (value - lo) / (hi - lo);
  if (includesZero) svg.append(investmentGraphic('line', {x1: 8, x2: 632, y1: y(0), y2: y(0), class: 'investment-axis'}));
  for (const [key, color] of series) {
    let starts = true;
    const commands = [];
    for (const point of points) {
      if (point[key] == null) { starts = true; continue; }
      const x = firstTime === lastTime ? 320 : 8 + 624 * (Date.parse(point.day) - firstTime) / (lastTime - firstTime);
      commands.push(`${starts ? 'M' : 'L'}${x},${y(Number(point[key]))}${starts ? 'h.01' : ''}`);
      starts = false;
    }
    if (commands.length) svg.append(investmentGraphic('path', {d: commands.join(' '), class: `investment-line investment-${color}`}));
  }
  return svg;
}

function investmentOverview(tables) {
  const days = investmentByDate(tables.investment_daily_snapshots);
  const latest = days.at(-1);
  const accounts = investmentByOrder(tables.investment_accounts);
  const snapshots = new Map((tables.investment_account_daily_snapshots ?? [])
    .filter(row => row.snapshot_date === latest?.snapshot_date).map(row => [row.account_id, row]));
  const summary = investmentCard('日终总览', node('p', latest ? `${latest.snapshot_date} · ${investmentSnapshotStatus[latest.status] ?? '已同步'}` : '暂无已同步的日终快照。', 'muted'),
    investmentMetrics([['总资产 · CNY', investmentMoney(latest?.total_cny)], ['折合美元', investmentMoney(latest?.total_usd, 'USD')],
      ['当日盈亏', investmentMoney(latest?.daily_gain_cny)], ['历史总盈亏', investmentMoney(latest?.cumulative_gain_cny)]]));
  const accountRows = accounts.filter(account => !account.archived_at).map(account => {
    const snapshot = snapshots.get(account.id);
    return [account.name, account.currency, investmentMoney(snapshot?.cash_native, account.currency),
      investmentMoney(snapshot?.holdings_native, account.currency), investmentMoney(snapshot?.gain_native, account.currency)];
  });
  return [summary, investmentCurve(days), investmentCalendar(days), investmentCard('账户盈亏',
    investmentTable(['账户', '币种', '现金余额', '持仓估值', '累计盈亏'], accountRows, '暂无账户。'))];
}

function investmentCurve(days) {
  const label = node('label', '时间范围', 'investment-filter');
  const range = node('select');
  for (const [caption, months] of [...investmentPeriods.slice(1), ['全部', 'all']]) {
    const option = node('option', caption);
    option.value = String(months);
    range.append(option);
  }
  range.value = investmentChartRange;
  label.append(range);
  const content = node('div');
  function draw() {
    investmentChartRange = range.value;
    const end = days.at(-1)?.snapshot_date;
    const start = end && range.value !== 'all' ? investmentBefore(end, Number(range.value)) : '';
    const points = days.filter(row => row.snapshot_date >= start).map(row => ({day: row.snapshot_date, assets: row.total_cny}));
    const chart = investmentLineChart(points, [['assets', 'assets']], '人民币总资产曲线');
    const period = points.length ? [node('p', `${points[0].day} 至 ${end} · 人民币`, 'muted')] : [];
    content.replaceChildren(...period, chart);
  }
  range.addEventListener('change', draw);
  draw();
  return investmentCard('资产变化曲线', label, content);
}

function investmentCalendar(days) {
  const label = node('label', '月份', 'investment-filter'), field = node('input'), calendar = node('div');
  field.type = 'month';
  field.value = investmentMonth || days.at(-1)?.snapshot_date.slice(0, 7) || new Date().toISOString().slice(0, 7);
  label.append(field);
  const amounts = new Map(days.map(row => [row.snapshot_date, row.daily_gain_cny]));
  function draw() {
    if (!field.value) return;
    investmentMonth = field.value;
    const first = new Date(field.value + '-01T00:00:00Z');
    const offset = (first.getUTCDay() + 6) % 7;
    const count = new Date(Date.UTC(first.getUTCFullYear(), first.getUTCMonth() + 1, 0)).getUTCDate();
    const grid = node('div', undefined, 'investment-calendar');
    for (const day of '一二三四五六日') grid.append(node('span', day, 'muted'));
    for (let i = 0; i < offset; i++) grid.append(node('span'));
    for (let day = 1; day <= count; day++) {
      const key = field.value + '-' + String(day).padStart(2, '0');
      const amount = amounts.get(key), cell = node('div', undefined, 'investment-day');
      cell.append(node('span', String(day)), node('strong', investmentMoney(amount),
        Number(amount) > 0 ? 'investment-gain' : Number(amount) < 0 ? 'investment-loss' : 'muted'));
      grid.append(cell);
    }
    calendar.replaceChildren(grid);
  }
  field.addEventListener('change', draw);
  draw();
  return investmentCard('盈亏日历', label, calendar);
}

function investmentAccounts(tables) {
  const accounts = investmentByOrder(tables.investment_accounts).filter(account => !account.archived_at);
  if (!accounts.length) return [investmentCard('投资账户', node('p', '暂无投资账户。', 'empty'))];
  const assets = new Map((tables.investment_assets ?? []).map(asset => [asset.id, asset]));
  const details = new Map((tables.investment_derivative_event_details ?? []).map(row => [row.event_id, row]));
  const select = node('select'), label = node('label', '账户', 'investment-filter'), content = node('div');
  for (const account of accounts) {
    const option = node('option', account.name + ' · ' + account.currency);
    option.value = account.id;
    select.append(option);
  }
  select.value = accounts.find(account => account.id === investmentSelectedAccount)?.id ?? accounts[0].id;
  label.append(select);
  function draw() {
    investmentSelectedAccount = select.value;
    const account = accounts.find(account => account.id === select.value);
    const {id, currency} = account;
    const snapshot = investmentByDate(tables.investment_account_daily_snapshots).findLast(row => row.account_id === id);
    const accountTotal = snapshot?.cash_native != null && snapshot.holdings_native != null ?
      investmentSum(snapshot.cash_native, snapshot.holdings_native) : undefined;
    const events = (tables.investment_events ?? []).filter(row => row.account_id === id && !row.deleted_at)
      .sort((a, b) => b.effective_date.localeCompare(a.effective_date) || Number(b.sequence) - Number(a.sequence));
    const tracked = [...new Set(events.map(row => row.asset_id).filter(Boolean))].map(assetID => {
      const asset = assets.get(assetID);
      return [asset?.name, asset?.symbol, investmentAssetTypes[asset?.asset_type], asset?.quote_currency];
    });
    const rows = events.map(event => {
      const asset = assets.get(event.asset_id), derivative = details.get(event.id);
      const deposit = ['deposit', 'certificate'].includes(asset?.asset_type);
      const title = deposit ? ({buy: '存入', sell: '支取', income: '支取利息'}[event.event_type] ?? investmentEventTypes[event.event_type]) :
        ({open_long: '开多', close_long: '平多', open_short: '开空', close_short: '平空'}[derivative?.trade_action] ?? investmentEventTypes[event.event_type]);
      const amount = deposit && ['buy', 'sell', 'opening'].includes(event.event_type) ? event.unit_price :
        !deposit && event.settled_amount != null ? event.settled_amount : Number(event.amount) ? event.amount : undefined;
      return [event.effective_date, title ?? event.event_type, asset?.name, deposit ? '—' : event.quantity,
        deposit ? '—' : event.unit_price, investmentMoney(amount, currency),
        deposit ? investmentMoney(event.settled_amount, currency) : '—'];
    });
    const plans = investmentByOrder(tables.investment_plans).filter(plan => plan.account_id === id).map(plan =>
      [assets.get(plan.asset_id)?.name ?? '定期转入', investmentMoney(plan.amount, currency), plan.next_date,
        plan.enabled === '1' ? '启用' : '停用', plan.last_result]);
    content.replaceChildren(
      investmentCard(account.name, node('p', `${investmentAccountTypes[account.account_type] ?? account.account_type} · ${currency} · ` +
        (snapshot ? `日终快照 ${snapshot.snapshot_date}` : '暂无日终快照'), 'muted'),
      investmentMetrics([['账户总资产', investmentMoney(accountTotal, currency)], ['现金余额', investmentMoney(snapshot?.cash_native, currency)],
        ['持仓估值', investmentMoney(snapshot?.holdings_native, currency)], ['累计盈亏', investmentMoney(snapshot?.gain_native, currency)]])),
      investmentCard('账本标的', investmentTable(['名称', '代码', '类型', '报价币种'], tracked, '暂无资产标的。')),
      investmentCard('账户流水', investmentTable(['日期', '类型', '标的', '数量', '成交价', '金额', '操作后存款余额'], rows)),
      investmentCard('定投任务', investmentTable(['任务', '金额', '下次执行', '状态', '上次结果'], plans, '暂无定投任务。'))
    );
  }
  select.addEventListener('change', draw);
  draw();
  return [label, content];
}

function investmentWatchlist(tables) {
  const assets = new Map((tables.investment_assets ?? []).map(asset => [asset.id, asset]));
  const market = new Map(), manual = new Map();
  function group(target, key, quote) {
    if (!target.has(key)) target.set(key, []);
    target.get(key).push(quote);
  }
  for (const row of tables.market_daily_prices ?? []) group(market, row.instrument_id, {
    day: row.session_date, price: row.price, source: row.source, final: row.is_final === '1', revision: Number(row.revision || 0)
  });
  for (const row of tables.investment_manual_prices ?? []) group(manual, row.asset_id, {
    day: row.valuation_date, price: row.value, source: row.source, final: row.is_final === '1', revision: 0
  });
  const rows = investmentByOrder(tables.investment_watchlist).flatMap(watch => {
    const asset = assets.get(watch.asset_id);
    if (!asset) return [];
    const quotes = [...(market.get(watch.instrument_id ?? asset.instrument_id) ?? []), ...(manual.get(asset.id) ?? [])]
      .filter(quote => Number(quote.price) > 0)
      .sort((a, b) => a.day.localeCompare(b.day) || Number(a.source === '手动录入') - Number(b.source === '手动录入') ||
        Number(a.final) - Number(b.final) || a.revision - b.revision);
    const latest = quotes.at(-1);
    const changes = investmentPeriods.map(([, months, days]) => {
      const start = latest && investmentBefore(latest.day, months, days);
      const base = start && quotes.findLast(quote => quote.day <= start);
      return base ? investmentPercent.format(Number(latest.price) / Number(base.price) - 1) : '—';
    });
    return [[asset.name, asset.symbol, investmentAssetTypes[asset.asset_type],
      latest ? investmentNumber.format(latest.price) + ' ' + asset.quote_currency : '—',
      latest ? `${latest.day} · ${latest.source ?? '已同步'}` : '待报价', ...changes]];
  });
  return [investmentCard('关注列表', investmentTable(['名称', '代码', '类型', '最新报价', '报价日期与来源',
    ...investmentPeriods.map(([label]) => label)], rows, '暂无关注标的。'))];
}

const investmentBalanceAssets = ['cash', 'investments', 'fixed', 'receivables'];
const investmentBalanceLabels = {assets: '总资产', ...investmentCategories, liabilities: '总负债', net: '净资产'};
const investmentBeijingDate = new Intl.DateTimeFormat('sv-SE', {timeZone: 'Asia/Shanghai', dateStyle: 'short'});

function investmentNegate(value) { return value.startsWith('-') ? value.slice(1) : '-' + value; }

function investmentBalanceTotals(balances, invested) {
  const investments = Number(invested) < 0 ? '0' : invested;
  const deficit = Number(invested) < 0 ? investmentNegate(invested) : '0';
  const assets = investments == null ? undefined : investmentSum(balances.cash, balances.fixed, balances.receivables, investments);
  const liabilities = investmentSum(balances.liabilities, deficit);
  return {...balances, investments: invested, assets, liabilities,
    net: assets == null ? undefined : investmentSum(assets, investmentNegate(liabilities))};
}

function investmentMonthEnd(year, month) {
  const day = new Date(0);
  day.setUTCFullYear(year, month, 0);
  return day.toISOString().slice(0, 10);
}

function investmentBalanceHistory(records, accountsByID, days, months, latestValue, hasInvestment) {
  const dated = records.flatMap(record => {
    const category = accountsByID.get(record.balance_account_id)?.category;
    const timestamp = Date.parse(record.recorded_at);
    return category && Number.isFinite(timestamp) ? [{...record, category, day: investmentBeijingDate.format(timestamp)}] : [];
  });
  const observations = [dated[0]?.day, dated.at(-1)?.day, days[0]?.snapshot_date, days.at(-1)?.snapshot_date,
    months[0]?.snapshot_date, months.at(-1)?.snapshot_date].filter(Boolean).sort();
  if (!observations.length) return {points: [], monthEnds: []};
  const start = observations[0], end = observations.at(-1);
  const daily = new Map(days.map(row => [row.snapshot_date, row.total_cny]));
  const monthly = new Map(months.map(row => [row.snapshot_date, row.total_cny]));
  const monthEnds = [];
  let year = Number(start.slice(0, 4)), month = Number(start.slice(5, 7));
  while (true) {
    const close = investmentMonthEnd(year, month);
    monthEnds.push(close < end ? close : end);
    if (close >= end) break;
    if (++month === 13) { year++; month = 1; }
  }
  const dates = [...new Set([start, ...monthEnds, ...dated.map(record => record.day)])].sort();
  const balances = {cash: '0', fixed: '0', receivables: '0', liabilities: '0'};
  const latestBalances = new Map();
  let offset = 0;
  const points = dates.map(day => {
    while (offset < dated.length && dated[offset].day <= day) {
      const record = dated[offset++], id = record.balance_account_id;
      balances[record.category] = investmentSum(balances[record.category], record.amount,
        investmentNegate(latestBalances.get(id) ?? '0'));
      latestBalances.set(id, record.amount);
    }
    const year = Number(day.slice(0, 4)), month = Number(day.slice(5, 7));
    const monthEnd = investmentMonthEnd(year, month), previousEnd = investmentMonthEnd(year, month - 1);
    let saved;
    if (day === end) saved = daily.has(day) ? daily.get(day) ?? monthly.get(day) : latestValue;
    else if (day === monthEnd) saved = monthly.get(day) ?? daily.get(day);
    else if (daily.has(day)) saved = daily.get(day);
    else saved = monthly.get(previousEnd) ?? daily.get(previousEnd);
    if (saved == null && (!hasInvestment || (days[0] && day < days[0].snapshot_date))) saved = '0';
    return {day, ...investmentBalanceTotals(balances, saved)};
  });
  const byDay = new Map(points.map(point => [point.day, point]));
  return {points, monthEnds: monthEnds.map(day => byDay.get(day))};
}

function investmentBalanceComparison({points, monthEnds}) {
  const current = points.at(-1);
  if (!current) return node('p', '暂无余额记录。', 'muted');
  const priorDay = investmentMonthEnd(Number(current.day.slice(0, 4)), Number(current.day.slice(5, 7)) - 1);
  const previous = monthEnds.find(point => point.day === priorDay);
  const section = node('section', undefined, 'investment-comparison');
  section.append(node('h3', `较上月底 · ${priorDay}`));
  if (!previous) {
    section.append(node('p', '暂无上月底余额。', 'muted'));
    return section;
  }
  const delta = key => current[key] == null || previous[key] == null ? undefined :
    investmentSum(current[key], investmentNegate(previous[key]));
  const signed = value => (Number(value) > 0 ? '+' : '') + investmentMoney(value);
  section.append(node('p', `总资产 ${signed(delta('assets'))} · 总负债 ${signed(delta('liabilities'))}`, 'muted'));
  const changes = Object.keys(investmentCategories).map(key => [key, delta(key)]);
  const max = Math.max(1, ...changes.map(([, value]) => Math.abs(Number(value ?? 0))));
  for (const [key, value] of changes) {
    const width = Math.abs(Number(value ?? 0)) / max * 50;
    const graphic = investmentGraphic('svg', {viewBox: '0 0 100 5', preserveAspectRatio: 'none', 'aria-hidden': 'true'});
    graphic.append(investmentGraphic('rect', {x: Number(value) < 0 ? 50 - width : 50, y: 0, width, height: 5,
      class: `investment-month-bar investment-${key}`}));
    const item = node('div', undefined, 'investment-comparison-row');
    item.append(node('span', investmentBalanceLabels[key]), graphic, node('strong', signed(value)));
    section.append(item);
  }
  return section;
}

function investmentBalanceComposition(balance) {
  const left = investmentBalanceAssets.map(key => [key, investmentBalanceLabels[key], balance[key]]);
  if (Number(balance.net) < 0) left.push(['net', '净资产缺口', investmentNegate(balance.net)]);
  const right = [['liabilities', '总负债', balance.liabilities], ['net', '净资产', balance.net]];
  const total = Math.max(Number(balance.assets), Number(balance.liabilities));
  if (!Number.isFinite(total) || total <= 0) {
    return investmentCard('资产构成', node('p', '暂无完整的资产构成数据。', 'empty'));
  }
  const svg = investmentGraphic('svg', {viewBox: '0 0 640 160', role: 'img',
    'aria-label': '资产、负债与净资产构成图'});
  const legend = node('div', undefined, 'investment-chart-legend');
  for (const [side, bands] of [left, right].entries()) {
    const active = bands.filter(([, , value]) => Number(value) > 0);
    const [x0, x1] = side ? [323, 610] : [30, 317];
    let outer = 20 - (active.length - 1) * 4, inner = 20;
    for (const [key, label, value] of active) {
      const width = Number(value) / total * 120;
      const [y0, y1] = side ? [inner, outer] : [outer, inner];
      const middle = (x0 + x1) / 2;
      const d = `M${x0},${y0} C${middle},${y0} ${middle},${y1} ${x1},${y1} v${width} ` +
        `C${middle},${y1 + width} ${middle},${y0 + width} ${x0},${y0 + width} Z`;
      const band = investmentGraphic('path', {d, class: `investment-band investment-${key}`});
      const tooltip = investmentGraphic('title', {});
      tooltip.textContent = `${label} ${investmentMoney(value)}`;
      band.append(tooltip);
      svg.append(band);
      legend.append(node('span', tooltip.textContent, `investment-chart-key investment-${key}`));
      outer += width + 8;
      inner += width;
    }
  }
  svg.append(investmentGraphic('rect', {x: 317, y: 20, width: 6, height: 120, class: 'investment-center'}));
  return investmentCard('资产构成', svg, legend);
}

function investmentSelect(title, options) {
  const label = node('label', title, 'investment-filter'), select = node('select');
  for (const [value, title] of options) {
    const option = node('option', title);
    option.value = value;
    select.append(option);
  }
  select.value = options[0][0];
  label.append(select);
  return {label, select};
}

function investmentBalanceTrend(points) {
  if (!points.length) return investmentCard('资产趋势', node('p', '暂无资产趋势记录。', 'empty'));
  const {label: rangeLabel, select: range} = investmentSelect('趋势范围', [['all', '记账以来'], ['year', '今年'], ['rolling', '近一年']]);
  const {label: modeLabel, select: mode} = investmentSelect('图表', [['balance', '资产与负债'], ['net', '净资产趋势']]);
  const controls = node('div', undefined, 'investment-chart-controls'), content = node('div');
  controls.append(rangeLabel, modeLabel);
  function draw() {
    const end = points.at(-1).day;
    const start = range.value === 'rolling' ? investmentBefore(end, 12) : range.value === 'year' ? end.slice(0, 4) + '-01-01' : '';
    const visible = points.filter(point => point.day >= start);
    const series = mode.value === 'net' ? [['net', 'net']] : [['assets', 'assets'], ['debt', 'liabilities']];
    const data = visible.map(point => ({...point, debt: investmentNegate(point.liabilities)}));
    const title = mode.value === 'net' ? '净资产趋势' : '资产与负债趋势，负债位于零轴下方';
    const legend = node('div', undefined, 'investment-chart-legend');
    for (const [, key] of series) legend.append(node('span', investmentBalanceLabels[key], `investment-chart-key investment-${key}`));
    content.replaceChildren(node('p', `${visible[0].day} 至 ${end} · 人民币`, 'muted'),
      investmentLineChart(data, series, title, mode.value !== 'net'), legend);
  }
  range.addEventListener('change', draw);
  mode.addEventListener('change', draw);
  draw();
  return investmentCard('资产趋势', controls, content);
}

function investmentBalanceCalendar(points) {
  if (!points.length) return investmentCard('资产月历', node('p', '暂无月度记录。', 'empty'));
  const years = [...new Set(points.map(point => point.day.slice(0, 4)))].reverse();
  const {label, select} = investmentSelect('年份', years.map(year => [year, `${year} 年`]));
  const charts = node('div', undefined, 'investment-month-charts');
  function draw() {
    const months = new Map(points.filter(point => point.day.startsWith(select.value)).map(point => [Number(point.day.slice(5, 7)), point]));
    charts.replaceChildren(...Object.entries(investmentBalanceLabels).map(([key, title]) => {
      const values = [...months.values()].flatMap(point => point[key] == null ? [] : [Number(point[key])]);
      const lo = Math.min(0, ...values), hi = Math.max(0, ...values);
      const y = value => hi === lo ? 58 : 58 - 50 * (value - lo) / (hi - lo);
      const chart = investmentGraphic('svg', {viewBox: '0 0 360 77', role: 'img', 'aria-label': `${select.value} 年${title}月度柱状图`});
      chart.append(investmentGraphic('line', {x1: 5, x2: 355, y1: y(0), y2: y(0), class: 'investment-axis'}));
      for (let month = 1; month <= 12; month++) {
        const x = (month - 0.5) * 30, value = months.get(month)?.[key];
        if (value != null) {
          const height = Math.max(1, Math.abs(y(Number(value)) - y(0)));
          const bar = investmentGraphic('rect', {x: x - 7, y: Math.min(y(Number(value)), y(0)), width: 14, height,
            class: `investment-month-bar investment-${key}`});
          const tooltip = investmentGraphic('title', {});
          tooltip.textContent = `${month} 月 ${investmentMoney(value)}`;
          bar.append(tooltip);
          chart.append(bar);
        }
        const caption = investmentGraphic('text', {x, y: 73, 'text-anchor': 'middle'});
        caption.textContent = `${month}`;
        chart.append(caption);
      }
      const panel = node('section', undefined, 'investment-month-chart');
      panel.append(node('h3', title), values.length ? chart : node('p', '暂无月度数据。', 'muted'));
      return panel;
    }));
  }
  select.addEventListener('change', draw);
  draw();
  return investmentCard('资产月历', label, node('p', '展示月末余额。最新月份展示截至最近记录的余额。', 'muted'), charts);
}

function investmentBalanceSheet(tables) {
  const accounts = investmentByOrder(tables.investment_balance_accounts);
  const accountsByID = new Map(accounts.map(account => [account.id, account]));
  const records = investmentByDate(tables.investment_balance_records, 'recorded_at');
  const latestByAccount = new Map(records.map(record => [record.balance_account_id, record]));
  const manual = accounts.filter(account => latestByAccount.has(account.id));
  const days = investmentByDate(tables.investment_daily_snapshots);
  const months = investmentByDate(tables.investment_month_snapshots);
  const investment = [days.findLast(row => row.total_cny != null), months.at(-1)].filter(Boolean)
    .sort((a, b) => a.snapshot_date.localeCompare(b.snapshot_date)).at(-1);
  const hasInvestment = days.length > 0 || months.length > 0 || (tables.investment_accounts ?? []).some(account => !account.archived_at);
  const invested = investment?.total_cny ?? (hasInvestment ? undefined : '0');
  const balances = Object.fromEntries(Object.keys(investmentCategories).map(category => [category,
    investmentSum(...manual.filter(account => account.category === category).map(account => latestByAccount.get(account.id).amount))]));
  const balance = investmentBalanceTotals(balances, invested);
  const {assets, liabilities: debt, net} = balance;
  const items = Object.entries(investmentCategories).map(([key, caption]) => [caption, investmentMoney(balance[key])]);
  const history = investmentBalanceHistory(records, accountsByID, days, months, invested, hasInvestment);
  return [investmentCard('资产负债汇总', node('p', investment ? `投资理财取自 ${investment.snapshot_date} 的已保存快照。` : '暂无已同步的投资估值快照。', 'muted'),
    investmentMetrics([['总资产', investmentMoney(assets)], ['总负债', investmentMoney(debt)], ['净资产', investmentMoney(net)],
      ['资产负债率', Number(assets) > 0 ? investmentRatio.format(Number(debt) / Number(assets)) : '—']]),
    investmentBalanceComparison(history), investmentTable(['分类', '金额 · CNY'], items)),
  investmentBalanceComposition(balance), investmentBalanceTrend(history.points), investmentBalanceCalendar(history.monthEnds),
  investmentCard('余额账户', investmentTable(['账户', '分类', '最近余额', '更新时间'], manual.map(account => {
    const record = latestByAccount.get(account.id);
    return [account.name, investmentCategories[account.category], investmentMoney(record.amount, account.currency), date(record.recorded_at)];
  }), '暂无手工余额账户。')),
  investmentCard('余额变动记录', investmentTable(['时间', '账户', '分类', '变动后余额'], [...records].reverse().flatMap(record => {
    const account = accountsByID.get(record.balance_account_id);
    return account ? [[date(record.recorded_at), account.name, investmentCategories[account.category], investmentMoney(record.amount, account.currency)]] : [];
  }))),
  investmentCard('投资理财月末快照', investmentTable(['日期', '投资理财 · CNY'], [...months].reverse().map(row =>
    [row.snapshot_date, investmentMoney(row.total_cny)])))];
}
