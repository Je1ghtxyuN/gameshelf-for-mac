'use strict';
let token = ''; // Memory only. Reloading the page requires sign-in.
const $ = id => document.getElementById(id);
const message = text => { $('message').textContent = text; };
function node(tag, text) { const n = document.createElement(tag); if (text) n.textContent = text; return n; }
async function api(path, method = 'GET', body) {
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers.Authorization = 'Bearer ' + token;
  const r = await fetch(path, {method, headers, body: body === undefined ? undefined : JSON.stringify(body), cache: 'no-store', credentials: 'omit'});
  const result = await r.json();
  if (!r.ok) throw new Error(result.error?.message || 'Request failed');
  return result;
}
function button(label, action) {
  const b = node('button', label); b.type = 'button';
  b.onclick = () => work(action); return b;
}
async function work(action) {
  message('Working… 处理中…');
  try { await action(); message('Done 完成'); } catch (e) { message(e.message); }
}
function choices(select, rows, label) {
  select.replaceChildren(...rows.map(r => { const o = node('option', label(r)); o.value = r.id; return o; }));
}
async function refresh() {
  const roots = (await api('/api/admin/roots')).roots;
  const candidates = (await api('/api/admin/candidates')).candidates;
  const users = (await api('/api/admin/users')).users;
  const games = (await api('/api/admin/games')).games;
  const grants = (await api('/api/admin/grants')).grants;
  $('roots').replaceChildren(...roots.map(r => {
    const row = node('div', r.title + ' · ' + r.path);
    row.append(button('Scan 扫描', async () => {
      const result = await api('/api/admin/roots/' + r.id + '/scan', 'POST', {});
      await refresh();
      if (!result.complete) throw new Error(result.issues.join('; '));
    })); return row;
  }));
  $('candidates').replaceChildren(...candidates.map(c => {
    const row = node('div'); row.className = 'candidate';
    const checkbox = node('input'); checkbox.type = 'checkbox'; checkbox.value = c.id;
    checkbox.disabled = !c.available;
    const summary = node('span', c.title + ' · ' + c.relative + ' · ' + c.entries.map(e => e.path).join(', ') + (c.available ? '' : ' (unavailable)'));
    const rules = node('p', 'Detected seed-save exclusions 已检测存档遮蔽: ' + JSON.stringify(c.detectedSavePaths));
    const config = node('textarea'); config.dataset.candidateId = c.id; config.value = '[]'; config.rows = 3;
    config.setAttribute('aria-label','Additional savePaths JSON for ' + c.title);
    const label = node('label','Additional savePaths JSON 自定义存档路径（文件/目录）'); label.append(config);
    row.append(checkbox, summary, rules, label);
    return row;
  }));
  $('users').replaceChildren(...users.map(u => {
    const row = node('div', u.username + (u.admin ? ' · admin' : '') + (u.disabled ? ' · disabled' : ''));
    if (!u.disabled) row.append(button('Disable 停用', async () => {
      await api('/api/admin/users/' + u.id + '/disable', 'POST', {}); await refresh();
    })); return row;
  }));
  const form = $('grant-form');
  choices(form.elements.userID, users.filter(u => !u.disabled), u => u.username);
  choices(form.elements.gameID, games, g => g.title + ' · ' + g.id.slice(0, 8));
  $('covers').replaceChildren(...games.map(g => {
    const row = node('div', g.title);
    const input = node('input'); input.type = 'file'; input.accept = 'image/jpeg';
    input.setAttribute('aria-label', 'JPEG · ' + g.title);
    row.append(input, button('Upload cover 上传封面', async () => {
      const file = input.files[0];
      if (!file || file.size > 256 * 1024) throw new Error('JPEG ≤ 256 KiB');
      const bytes = new Uint8Array(await file.arrayBuffer());
      let binary = ''; for (const byte of bytes) binary += String.fromCharCode(byte);
      await api('/api/admin/games/' + g.id + '/cover', 'POST', {data: btoa(binary)});
      input.value = '';
    })); return row;
  }));
  $('grants').replaceChildren(...grants.map(g => node('div',
    (users.find(u => u.id === g.userID)?.username || g.userID) + ' → ' +
    (games.find(game => game.id === g.gameID)?.title || g.gameID))));
}
$('login').onsubmit = e => { e.preventDefault(); work(async () => {
  const f = e.target;
  const password = f.elements.password.value; f.elements.password.value = '';
  const result = await api('/api/login', 'POST', { username: f.elements.username.value, password });
  token = result.token;
  if (!result.user.admin) { await api('/api/logout', 'POST', {}); token = ''; throw new Error('Administrator required 需要管理员账号'); }
  $('account').textContent = result.user.username;
  $('login').hidden = true; $('admin').hidden = false; await refresh();
}); };
$('root-form').onsubmit = e => { e.preventDefault(); work(async () => {
  const f = e.target; await api('/api/admin/roots', 'POST', {title:f.elements.title.value, path:f.elements.path.value}); f.reset(); await refresh();
}); };
$('user-form').onsubmit = e => { e.preventDefault(); work(async () => {
  const f = e.target; const password = f.elements.password.value; f.elements.password.value = '';
  await api('/api/admin/users', 'POST', {username:f.elements.username.value, password, admin:f.elements.admin.checked}); f.reset(); await refresh();
}); };
$('grant-form').onsubmit = e => { e.preventDefault(); work(async () => {
  const f = e.target; await api('/api/admin/grants', 'POST', {userID:f.elements.userID.value, gameID:f.elements.gameID.value, allowed:e.submitter.value === 'true'}); await refresh();
}); };
$('publish').onclick = () => work(async () => {
  const ids = Array.from($('candidates').querySelectorAll('input:checked')).map(n => n.value);
  if (!ids.length) throw new Error('Select candidates first 请先勾选候选游戏');
  for (const id of ids) {
    const editor = Array.from($('candidates').querySelectorAll('textarea')).find(n => n.dataset.candidateId === id);
    const savePaths = JSON.parse(editor.value);
    if (!Array.isArray(savePaths)) throw new Error('savePaths must be a JSON array');
    await api('/api/admin/candidates/' + id + '/publish', 'POST', {savePaths});
  }
  await refresh();
});
$('refresh').onclick = () => work(refresh);
$('logout').onclick = () => work(async () => {
  try { await api('/api/logout', 'POST', {}); }
  finally { token = ''; $('admin').hidden = true; $('login').hidden = false; }
});

$('download-invitation').onclick = () => work(async () => {
  const invitation = await api('/api/admin/invitation');
  const blob = new Blob([JSON.stringify(invitation, null, 2) + '\n'], {type: 'application/json'});
  const url = URL.createObjectURL(blob);
  const link = node('a');
  link.href = url; link.download = 'gameshelf-invitation.json';
  document.body.append(link);
  try { link.click(); }
  finally { link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
});

$('setup').onsubmit = e => { e.preventDefault(); work(async () => {
  const f = e.target, file = f.elements.invitation.files[0];
  const password = f.elements.password.value, confirmation = f.elements.confirmation.value;
  f.elements.password.value = ''; f.elements.confirmation.value = '';
  if (password !== confirmation) throw new Error('Passwords do not match 密码不一致');
  if (!file || file.size > 4096) throw new Error('Invalid private invitation 无效私有邀请');
  const invitation = JSON.parse(await file.text());
  if (invitation.version !== 1 || invitation.kind !== 'administrator-setup' || typeof invitation.setupToken !== 'string' ||
      new URL(invitation.address).origin !== window.location.origin)
    throw new Error('Private invitation does not match 此私有邀请不匹配');
  const result = await api('/api/setup', 'POST', {setupToken: invitation.setupToken, username: f.elements.username.value, password});
  token = result.token; f.reset(); $('setup').hidden = true; $('login').hidden = true;
  $('account').textContent = result.user.username; $('admin').hidden = false; await refresh();
}); };
api('/api/server-info').then(info => {
  if (token) return;
  $('setup').hidden = !info.setupRequired; $('login').hidden = info.setupRequired;
}).catch(e => message(e.message));
