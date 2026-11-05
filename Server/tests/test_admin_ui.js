'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const script = fs.readFileSync(path.join(__dirname, '../gameshelf_server/web/admin.js'), 'utf8');
function fixture(setupRequired = false, games = []) {
  const elements = new Map(), requests = [];
  function element() {
    return {hidden: false, value: '', textContent: '', children: [], files: [], dataset: {},
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
      setAttribute() {}, querySelectorAll() { return []; }, reset() { this.resetCalled = true; }};
  }
  const document = { getElementById(id) { if (!elements.has(id)) elements.set(id, element()); return elements.get(id); },
    createElement() { return element(); } };
  for (const id of ['login','setup','user-form','root-form','grant-form']) document.getElementById(id).elements = {};
  document.getElementById('grant-form').elements = {userID: element(), gameID: element()};
  const fetch = async (route, options) => {
    const body = options.body === undefined ? undefined : JSON.parse(options.body);
    requests.push({route, body, headers: options.headers});
    let value = {};
    if (route === '/api/server-info') value = {setupRequired};
    else if (route === '/api/setup' || route === '/api/login') value = {token: 'private-http-token', user: {admin: true, username: 'owner'}};
    else if (route === '/api/admin/games') value = {games};
    else if (route === '/api/admin/roots') value = {roots: []};
    else if (route === '/api/admin/candidates') value = {candidates: []};
    else if (route === '/api/admin/users') value = {users: []};
    else if (route === '/api/admin/grants') value = {grants: []};
    return {ok: true, json: async () => value};
  };
  vm.runInNewContext(script, {document, fetch, URL, window: {location: {origin: 'https://library.example:8787'}},
    Uint8Array, btoa: value => Buffer.from(value, 'binary').toString('base64')});
  const drain = () => new Promise(resolve => setImmediate(resolve));
  return {get: id => document.getElementById(id), requests, drain, element};
}
test('empty-service setup submits private capability and clears password fields', async () => {
  const f = fixture(true); await f.drain();
  assert.equal(f.get('setup').hidden, false); assert.equal(f.get('login').hidden, true);
  const form = f.get('setup');
  form.elements = {invitation: {files: [{size: 250, text: async () => JSON.stringify({version: 1, kind: 'administrator-setup', address: 'https://library.example:8787', setupToken: 'private-capability'})}]},
    username: {value: 'owner'}, password: {value: 'private password'}, confirmation: {value: 'private password'}};
  form.onsubmit({preventDefault() {}, target: form}); await f.drain();
  assert.deepEqual(f.requests.find(r => r.route === '/api/setup').body,
    {setupToken: 'private-capability', username: 'owner', password: 'private password'});
  assert.equal(form.elements.password.value, ''); assert.equal(form.elements.confirmation.value, '');
  assert.equal(form.resetCalled, true); assert.equal(form.hidden, true); assert.equal(f.get('admin').hidden, false);
});
test('default-cover upload uses admin published-game route with bounded JPEG JSON', async () => {
  const game = {id: 'a'.repeat(32), title: 'Published fixture'};
  const f = fixture(false, [game]); await f.drain();
  const login = f.get('login'); login.elements = {username: {value: 'owner'}, password: {value: 'private password'}};
  login.onsubmit({preventDefault() {}, target: login}); await f.drain();
  const row = f.get('covers').children[0], [input, button] = row.children;
  const bytes = Buffer.from([255,216,255,217]);
  input.files = [{size: bytes.length, arrayBuffer: async () => bytes}];
  button.onclick(); await f.drain();
  const request = f.requests.find(r => r.route === '/api/admin/games/' + game.id + '/cover');
  assert.deepEqual(request.body, {data: bytes.toString('base64')});
  assert.equal(request.headers.Authorization, 'Bearer private-http-token');
  input.files = [{size: 256 * 1024 + 1, arrayBuffer() { throw Error('oversized file must not be read'); }}];
  button.onclick(); await f.drain();
  assert.equal(f.requests.filter(r => r.route.endsWith('/cover')).length, 1);
});
