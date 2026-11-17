'use strict';
let dataDatabases = [], dataDatabase = null, dataTable = null;
let dataExpandedDatabase = null;
let dataEpoch = 0, dataCatalogEpoch = 0, dataBusy = false, dataPage = null;

function resetDatabaseManager() {
  dataEpoch++; dataCatalogEpoch++;
  dataDatabases = []; dataDatabase = null; dataTable = null; dataBusy = false; dataPage = null;
  dataExpandedDatabase = null;
  for (const id of ['system-databases', 'data-results', 'data-columns']) $(id).replaceChildren();
  $('system-status').textContent = ''; $('data-sql').value = ''; $('system-filter').value = '';
  $('data-ddl').textContent = '选择一张表以查看结构。';
  $('data-table-title').textContent = '选择一张表'; $('data-database').textContent = 'DATA EXPLORER';
  $('data-result-status').textContent = '在左侧选择一张表以查看数据。';
  $('data-error').textContent = ''; $('data-error').hidden = true;
  $('system-refresh').disabled = false;
  setDataTab('rows'); updateDataControls();
}

async function refreshDatabaseSchemas() {
  if (currentPage !== 'system' || !csrf) return;
  const session = csrf, epoch = ++dataCatalogEpoch;
  $('system-refresh').disabled = true; $('system-status').textContent = '正在读取数据库…';
  try {
    const {databases} = await api('system/databases');
    if (csrf !== session || epoch !== dataCatalogEpoch) return;
    dataDatabases = databases;
    renderDataCatalog();
    $('system-status').textContent = `${databases.length} 个数据库 · 选择表查看数据与结构`;
    const db = databases.find(db => db.id === dataDatabase?.id && db.schema) ?? databases.find(db => db.schema?.tables.length);
    const table = db?.schema.tables.find(table => table.name === dataTable?.name) ?? db?.schema.tables[0];
    if (db) selectDataTable(db.id, table?.name);
  } catch (e) {
    if (csrf === session && epoch === dataCatalogEpoch) $('system-status').textContent = e.message;
  } finally {
    if (epoch === dataCatalogEpoch) $('system-refresh').disabled = false;
  }
}

function renderDataCatalog() {
  const filter = $('system-filter').value.trim().toLowerCase();
  const groups = [];
  for (const db of dataDatabases) {
    const match = (db.name + ' ' + db.file).toLowerCase().includes(filter);
    const tables = (db.schema?.tables ?? []).filter(t => match || t.name.toLowerCase().includes(filter));
    if (!match && !tables.length) continue;
    const group = node('details', undefined, 'data-database-group'); group.open = dataExpandedDatabase === db.id;
    const summary = node('summary');
    summary.addEventListener('click', event => {
      event.preventDefault();
      const open = !group.open;
      dataExpandedDatabase = open ? db.id : null;
      for (const other of groups) other.open = other === group && open;
    });
    summary.append(node('strong', db.name), node('span', db.schema ? `${db.schema.tables.length} 张表` : ({disabled:'未启用', not_created:'尚未创建', unreadable:'读取失败'}[db.status] || db.status), 'muted'));
    group.append(summary, node('p', db.file + (db.schema ? ` · 版本 ${db.schema.version}` : ''), 'data-file'));
    if (db.schema && db.schema.version !== db.expectedVersion) group.append(node('p', `期望版本 ${db.expectedVersion}，请检查迁移状态`, 'data-version-warning'));
    for (const table of tables) {
      const button = node('button', table.name, 'data-table-button'); button.type = 'button';
      button.setAttribute('aria-label', db.name + ' / ' + table.name);
      button.setAttribute('aria-pressed', String(dataDatabase?.id === db.id && dataTable?.name === table.name));
      button.addEventListener('click', () => selectDataTable(db.id, table.name)); group.append(button);
    }
    groups.push(group);
  }
  $('system-databases').replaceChildren(...(groups.length ? groups : [node('p', '没有匹配的数据库或表。', 'empty')]));
}

function dataGrid(columns, rows) {
  const table = node('table', undefined, 'data-grid'), head = node('thead'), headings = node('tr');
  for (const name of columns) { const th = node('th', name); th.setAttribute('scope', 'col'); headings.append(th); }
  head.append(headings); table.append(head);
  const body = node('tbody');
  for (const row of rows) {
    const tr = node('tr');
    for (const value of row) {
      const td = node('td', value === null ? 'NULL' : String(value), value === null ? 'data-null' : '');
      tr.append(td);
    }
    body.append(tr);
  }
  table.append(body); return table;
}

function selectDataTable(databaseID, tableName) {
  dataEpoch++; dataBusy = false; dataPage = null;
  dataDatabase = dataDatabases.find(db => db.id === databaseID && db.schema) ?? null;
  dataTable = dataDatabase?.schema.tables.find(table => table.name === tableName) ?? null;
  $('data-results').replaceChildren(); $('data-error').hidden = true;
  $('data-database').textContent = dataDatabase ? dataDatabase.name + ' / ' + dataDatabase.file : 'DATA EXPLORER';
  $('data-table-title').textContent = dataTable?.name ?? '选择一张表';
  $('data-sql').value = dataTable ? 'SELECT * FROM "' + dataTable.name.replaceAll('"', '""') + '";' : '';
  const columns = dataTable?.columns ?? [];
  $('data-columns').replaceChildren(...(dataTable ? [dataGrid(['字段', '类型', 'NOT NULL', '默认值', '主键', '生成列 / 隐藏'], columns.map(c => [c.name, c.type || '—', c.notNull ? '是' : '否', c.default, c.primaryKey ? String(c.primaryKey) : '—', ({0:'—',1:'隐藏',2:'VIRTUAL',3:'STORED'})[c.hidden] ?? String(c.hidden)]))] : []));
  $('data-ddl').textContent = dataTable ? [dataTable.sql, ...(dataTable.indexes ?? [])].join(';\n\n') + ';' : '选择一张表以查看结构。';
  $('data-result-status').textContent = dataTable ? '正在读取表数据…' : '请选择一张表。';
  renderDataCatalog(); updateDataControls();
  if (dataTable) void executeDatabaseQuery();
}

function setDataTab(tab) {
  for (const name of ['rows', 'schema']) {
    $('data-tab-' + name).setAttribute('aria-selected', String(tab === name));
    $('data-' + name + '-panel').hidden = tab !== name;
  }
}

function updateDataControls() {
  $('data-run').disabled = dataBusy || !dataDatabase;
  $('data-run').textContent = dataBusy ? '查询中…' : '执行查询';
  $('data-prev').disabled = dataBusy || !dataPage || dataPage.offset === 0;
  $('data-next').disabled = dataBusy || !dataPage?.hasMore;
  $('data-limit').disabled = dataBusy;
}

async function executeDatabaseQuery(direction = 0) {
  if (!dataDatabase || !csrf || dataBusy) return;
  const page = direction && dataPage ? {...dataPage, offset: Math.max(0, dataPage.offset + direction * dataPage.limit)} :
    {database: dataDatabase.id, sql: $('data-sql').value.trim(), limit: Number($('data-limit').value) || 100, offset: 0};
  if (!page.sql) { $('data-error').textContent = '请填写 SQL 查询。'; $('data-error').hidden = false; return; }
  const session = csrf, epoch = ++dataEpoch;
  dataBusy = true; updateDataControls(); $('data-error').hidden = true;
  $('data-result-status').textContent = '正在执行查询…';
  try {
    const result = await api('system/databases/' + encodeURIComponent(page.database) + '/query', 'POST', {sql: page.sql, limit: page.limit, offset: page.offset});
    if (csrf !== session || epoch !== dataEpoch) return;
    dataPage = {...page, hasMore: result.hasMore};
    $('data-results').replaceChildren(dataGrid(result.columns, result.rows));
    $('data-result-status').textContent = result.rows.length ? `第 ${result.offset + 1}–${result.offset + result.rows.length} 行${result.hasMore ? ' · 还有更多' : ''}${result.clipped ? ' · 超长字段已截断' : ''}` : '查询成功 · 没有数据';
  } catch (e) {
    if (csrf === session && epoch === dataEpoch) {
      dataPage = null; $('data-results').replaceChildren();
      $('data-error').textContent = e.message; $('data-error').hidden = false;
      $('data-result-status').textContent = '查询未完成';
    }
  } finally {
    if (epoch === dataEpoch) { dataBusy = false; updateDataControls(); }
  }
}

$('system-refresh').addEventListener('click', refreshDatabaseSchemas);
$('system-filter').addEventListener('input', renderDataCatalog);
$('data-tab-rows').addEventListener('click', () => setDataTab('rows'));
$('data-tab-schema').addEventListener('click', () => setDataTab('schema'));
$('data-query-form').addEventListener('submit', event => { event.preventDefault(); void executeDatabaseQuery(); });
$('data-sql').addEventListener('keydown', event => { if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') { event.preventDefault(); void executeDatabaseQuery(); } });
$('data-prev').addEventListener('click', () => executeDatabaseQuery(-1));
$('data-next').addEventListener('click', () => executeDatabaseQuery(1));
$('data-limit').addEventListener('change', () => executeDatabaseQuery());
