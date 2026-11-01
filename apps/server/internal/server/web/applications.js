'use strict';
Object.assign(messages, { invalid_application_details:'请填写应用名称和有效的 HTTPS 根地址。', too_many_applications:'最多支持 64 个应用。', application_not_found:'应用已不存在，请刷新列表。' });
let applicationsRefreshing = false;
function resetApplications() {
  $('application-dialog').close(); $('application-secret-dialog').close();
  $('application-configuration').value = ''; $('application-secret-title').textContent = '';
  $('application-list').replaceChildren(); $('application-error').hidden = true;
}
function showApplicationSecret(result) {
  $('application-secret-title').textContent = result.application.name + ' · ' + result.application.id;
  $('application-configuration').value = result.configuration;
  $('application-secret-dialog').showModal();
}
async function refreshApplications() {
  if (currentPage !== 'applications' || !csrf || applicationsRefreshing) return;
  applicationsRefreshing = true;
  try {
    const result = await api('applications');
    $('application-list').replaceChildren();
    if (!result.applications.length) { empty('application-list', '还没有应用。创建后，将生成的配置复制到 iLinker。'); return; }
    for (const app of result.applications) {
      const row = node('div', undefined, 'device'), info = node('div'), title = node('div', app.name, 'device-title');
      title.append(node('span', app.enabled ? '已启用' : '已停用', 'badge' + (app.enabled ? ' online' : '')));
      info.append(title, node('p', '应用 ID：' + app.id, 'device-meta'), node('p', app.origin, 'device-meta'), node('p', '创建时间：' + date(app.createdAt), 'device-meta'));
      const buttons = node('div', undefined, 'device-actions');
      buttons.append(action(app.enabled ? '停用' : '启用', async () => {
        if (app.enabled && !confirm('停用「' + app.name + '」？该应用的扫码请求和 Hako 登录授权将失效。')) return;
        await api('applications/' + encodeURIComponent(app.id), 'PATCH', { enabled: !app.enabled });
        await refreshApplications(); notice(app.enabled ? '应用已停用。' : '应用已启用，旧授权不会恢复。', true);
      }), action('轮换 SK', async () => {
        if (!confirm('为「' + app.name + '」生成新 SK？旧 SK、待登录请求和已签发的 Hako 授权将失效，请同步更新应用配置。')) return;
        const result = await api('applications/' + encodeURIComponent(app.id) + '/rotate', 'POST', {});
        if (!csrf) return;
        showApplicationSecret(result); notice('SK 已轮换，请更新 iLinker 配置并重启。', true);
      }, 'danger'));
      row.append(info, buttons); $('application-list').append(row);
    }
  } catch (error) { notice(error.message); }
  finally { applicationsRefreshing = false; }
}
$('applications-refresh').addEventListener('click', refreshApplications);
$('application-create').addEventListener('click', () => { $('application-error').hidden = true; $('application-dialog').showModal(); });
$('application-close').addEventListener('click', () => $('application-dialog').close());
$('application-secret-close').addEventListener('click', () => $('application-secret-dialog').close());
$('application-secret-dialog').addEventListener('close', () => { $('application-configuration').value = ''; $('application-secret-title').textContent = ''; });
$('application-secret-copy').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('application-configuration').value); notice('配置已复制，请保存到 iLinker 部署环境。', true); }
  catch { $('application-configuration').focus(); $('application-configuration').select(); notice('无法自动复制，请手动复制已选中的配置。'); }
});
$('application-form').addEventListener('submit', async event => {
  event.preventDefault(); const button = $('application-submit'); if (button.disabled) return;
  button.disabled = true; $('application-error').hidden = true;
  try {
    const result = await api('applications', 'POST', { name: $('application-name').value, origin: $('application-origin').value });
    if (!csrf) return;
    $('application-dialog').close(); $('application-form').reset();
    showApplicationSecret(result); await refreshApplications();
  } catch (error) { $('application-error').textContent = error.message; $('application-error').hidden = false; }
  finally { button.disabled = false; }
});
