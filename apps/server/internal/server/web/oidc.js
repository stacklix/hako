"use strict";
(async function poll() {
  try {
    const response = await fetch(location.pathname + '/status', {credentials: 'same-origin', cache: 'no-store', redirect: 'error'});
    if (!response.ok) { document.getElementById('status').textContent = '请求已失效，请返回应用重新登录。'; return; }
    const {status} = await response.json();
    document.getElementById('status').textContent = ({pending:'等待手机确认', scanned:'请在 Hako 中核对并明确批准', approved:'已批准，正在返回应用', denied:'已拒绝'})[status] || '请求已失效';
    if (status === 'approved' || status === 'denied') {
      const form = document.querySelector('form');
      form.requestSubmit(form.querySelector('button[value="continue"]'));
      return;
    }
  } catch { document.getElementById('status').textContent = '连接中断，可在手机确认后点击继续，或返回应用重试。'; }
  setTimeout(poll, 2000);
})();
