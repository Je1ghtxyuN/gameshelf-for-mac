'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const adapter = require('../Tools/shared_web_storage.js');
const fs = require('node:fs');
const vm = require('node:vm');
function freshAdapter() {
  const browser = {setTimeout};
  vm.runInNewContext(fs.readFileSync(require.resolve('../Tools/shared_web_storage.js'), 'utf8'), browser);
  return browser.GameShelfSharedWebStorage;
}
const turn = () => new Promise(resolve => setTimeout(resolve, 10));
function host(initial = []) {
  const values = new Map(initial), calls = [];
  return {values, calls, async send(body) {
    calls.push({...body});
    switch (body.op) {
      case 'get': return {value: values.has(body.key) ? values.get(body.key) : null};
      case 'set': values.set(body.key, body.value); return {value: null};
      case 'remove': values.delete(body.key); return {value: null};
      case 'keys': return {value: [...values.keys()]};
      case 'clear': values.clear(); return {value: null};
      default: throw Error('unknown operation');
    }
  }};
}
function original() {
  const target = {};
  for (const name of ['getItem', 'setItem', 'removeItem', 'clear', 'keys', 'length', 'key', 'iterate', 'ready', 'config', 'setDriver', 'driver', 'supports', 'createInstance']) {
    target[name] = () => { throw Error('Original IndexedDB must never be called'); };
  }
  return target;
}
test('install is write-free and strings persist through the host only, across facades and accounts', async () => {
  const a = host(), b = host(), local = original();
  assert.equal(adapter.install(local, body => a.send(body)), local);
  assert.equal(a.calls.length, 0);
  await local.ready(); await local.setDriver('asyncStorage');
  assert.equal(a.calls.length, 0);
  const value = '\0中文😀\xff';
  assert.equal(await local.setItem('../../file1', value), value);
  const reopened = adapter.install(original(), body => a.send(body));
  assert.equal(await reopened.getItem('../../file1'), value);
  const other = adapter.install(original(), body => b.send(body));
  assert.equal(await other.getItem('../../file1'), null);
  await local.setItem('config', 'settings');
  assert.deepEqual(await local.keys(), ['../../file1', 'config']);
  assert.equal(await local.length(), 2); assert.equal(await local.key(1), 'config');
  assert.equal(await local.key(-1), null); assert.equal(await local.key(10), null);
  const visits = [];
  assert.equal(await local.iterate((v, k, n) => { visits.push([v, k, n]); return n === 2 ? 'done' : undefined; }), 'done');
  assert.equal(visits.length, 2);
  await local.removeItem('../../file1'); assert.equal(await local.getItem('../../file1'), null);
  await local.clear(); assert.equal(await local.length(), 0);
  await adapter.flush();
});
test('Promise and callbacks resolve after host ACK, and operations remain ordered', async () => {
  const h = host(); let ack, callback = false, completed = false;
  const local = adapter.install(original(), body => body.op === 'set' ? new Promise(resolve => { ack = async () => resolve(await h.send(body)); }) : h.send(body));
  const saving = local.setItem('file1', 'zip', (error, value) => { assert.equal(error, null); assert.equal(value, 'zip'); callback = true; }).then(() => { completed = true; });
  const reading = local.getItem('file1');
  let flushed = false; const flushing = adapter.flush().then(() => { flushed = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(completed, false); assert.equal(callback, false); assert.equal(flushed, false); assert.equal(h.calls.length, 0);
  await ack(); await saving; assert.equal(await reading, 'zip'); await flushing;
  assert.equal(callback, true); assert.equal(flushed, true);
  assert.deepEqual(h.calls.map(c => c.op), ['set', 'get']);
});
test('failed mutations remain visible to global flush until successful retry or clear', async () => {
  const h = host(); let fail = true;
  const local = adapter.install(original(), body => fail && body.op === 'set' ? Promise.reject(Error('disk unavailable')) : h.send(body));
  await assert.rejects(local.setItem('file1', 'zip'), /disk unavailable/);
  await assert.rejects(adapter.flush(), /disk unavailable/);
  fail = false; await local.setItem('other', 'ok');
  await assert.rejects(adapter.flush(), /disk unavailable/);
  await local.setItem('file1', 'retry'); await adapter.flush();
  fail = true; await assert.rejects(local.setItem('file2', 'bad'));
  fail = false; await local.clear(); await adapter.flush();
});
test('remove and clear failures propagate, and createInstance operations are globally flushed', async () => {
  const h = host(); let failOp = 'remove';
  const local = adapter.install(original(), body => body.op === failOp ? Promise.reject(Error('host failure')) : h.send(body));
  await assert.rejects(local.removeItem('file1'), /host failure/);
  await assert.rejects(adapter.flush(), /host failure/);
  failOp = ''; await local.removeItem('file1'); await adapter.flush();
  failOp = 'clear'; await assert.rejects(local.clear()); await assert.rejects(adapter.flush());
  failOp = ''; await local.clear(); await adapter.flush();
  const instance = local.createInstance();
  await instance.setItem('instance', 'value'); await adapter.flush();
  assert.equal(await local.getItem('instance'), 'value');
});
test('binary values and malformed host replies reject without a fallback', async () => {
  const h = host(), local = adapter.install(original(), body => h.send(body));
  for (const value of [null, {}, new Uint8Array([1]), Buffer.from('x'), 3]) {
    await assert.rejects(local.setItem('invalid', value));
  }
  await local.removeItem('invalid'); await adapter.flush();
  assert.equal(h.calls.some(c => c.op === 'set'), false);
  const bad = adapter.install(original(), async () => ({value: 123}));
  await assert.rejects(bad.getItem('file1'));
  await assert.rejects(bad.keys());
});
test('browser export flush covers delayed operations from every install and clone', async () => {
  const browser = {setTimeout};
  vm.runInNewContext(fs.readFileSync(require.resolve('../Tools/shared_web_storage.js'), 'utf8'), browser);
  const api = browser.GameShelfSharedWebStorage;
  const a = host(), b = host(); let ack;
  const first = api.install(original(), body => a.send(body));
  const second = api.install(original(), body => new Promise(resolve => { ack = async () => resolve(await b.send(body)); }));
  const save1 = first.setItem('a', 'one');
  const save2 = second.createInstance().setItem('b', 'two');
  let done = false; const flushed = api.flush().then(() => { done = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(done, false); assert.equal(a.values.get('a'), 'one'); assert.equal(b.values.size, 0);
  await ack(); await Promise.all([save1, save2, flushed]); assert.equal(done, true);
});
test('configuration never silently merges a different createInstance namespace', async () => {
  const h = host(), sender = body => h.send(body), local = adapter.install(original(), sender);
  assert.equal(adapter.install(local, sender), local);
  assert.throws(() => adapter.install(local, body => h.send(body)), /rebind/);
  local.config({name: 'rmmzsave', storeName: 'rmmzsave'});
  const instance = local.createInstance({name: 'rmmzsave', storeName: 'rmmzsave'});
  assert.equal(instance.INDEXEDDB, 'asyncStorage');
  await instance.setDriver(instance.INDEXEDDB);
  await instance.setItem('file1', 'save');
  assert.throws(() => local.createInstance({name: 'other'}), /namespace/);
  assert.throws(() => local.config({storeName: 'other'}), /namespace/);
  const unconfigured = adapter.install(original(), sender);
  await unconfigured.setItem('file1', 'existing');
  assert.throws(() => unconfigured.createInstance({name: 'other'}), /namespace/);
  await adapter.flush();
});
test('UTF8 boundaries and callbacks fail closed, with no fallback or lost flush error', async () => {
  const h = host(), local = adapter.install(original(), body => h.send(body));
  let callbackError;
  await assert.rejects(local.setItem('bad', '\ud800', error => { callbackError = error; }));
  assert.ok(callbackError); await assert.rejects(adapter.flush());
  await local.setItem('bad', 'retry'); await adapter.flush();
  await assert.rejects(local.setItem('é'.repeat(513), 'x'));
  await local.clear(); await adapter.flush();
  await assert.rejects(local.setItem('file1', '😀'.repeat(1024 * 1024 + 1)));
  await local.removeItem('file1'); await adapter.flush();
  assert.equal(h.calls.filter(c => c.op === 'set').length, 1);
});
for (const failSecond of [false, true]) {
  test('flush follows temp→file1 continuation and its ACK/failure: ' + failSecond, async () => {
    const api = freshAdapter(), h = host(); let first, second, outcome = 'pending';
    const local = api.install(original(), body => {
      if (body.op !== 'set') return h.send(body);
      return new Promise((resolve, reject) => {
        const ack = () => resolve(h.send(body));
        if (body.key === 'temp') first = ack;
        else second = () => failSecond ? reject(Error('second write failed')) : ack();
      });
    });
    const saving = local.setItem('temp', 'zip').then(() => local.setItem('file1', 'zip'));
    const observedSaving = saving.then(() => null, error => error);
    const flushing = api.flush().then(() => { outcome = 'success'; }, error => { outcome = error.message; });
    await turn(); first(); await turn();
    assert.equal(typeof second, 'function');
    assert.equal(outcome, 'pending', 'flush must await the later write, not its captured old tail');
    second(); await observedSaving; await flushing;
    assert.equal(outcome, failSecond ? 'second write failed' : 'success');
  });
}
test('flush waits for full engine save promise, delayed compression and subsequent global index', async () => {
  const api = freshAdapter(), h = host(), local = api.install(original(), body => h.send(body));
  let compress, index, outcome = 'pending';
  const compression = new Promise(resolve => { compress = resolve; });
  const indexReady = new Promise(resolve => { index = resolve; });
  const storage = {
    tag: 'storage',
    saveObject(name, value) { assert.equal(this.tag, 'storage'); return compression.then(() => this.saveZip(name, value)); },
    saveZip(name, value) { return this.saveToForage(name, value); },
    saveToForage(name, value) { return local.setItem(name, value); },
    removeForage(name) { return local.removeItem(name); },
    loadObject() { return new Promise(() => {}); }
  };
  const data = {saveGame(id) { return storage.saveObject('file' + id, 'zip').then(() => indexReady).then(() => storage.saveObject('global', 'index')); }};
  api.trackMZEngine(storage, data, {});
  const wrapped = storage.saveObject, wrappedSave = data.saveGame, unwrappedLoad = storage.loadObject;
  api.trackMZEngine(storage, data, {});
  assert.equal(storage.saveObject, wrapped); assert.equal(data.saveGame, wrappedSave);
  assert.equal(storage.loadObject, unwrappedLoad); storage.loadObject();
  const saving = data.saveGame(1);
  const flushing = api.flush().then(() => { outcome = 'success'; });
  await turn(); assert.equal(outcome, 'pending'); assert.equal(h.calls.length, 0);
  compress(); await turn(); assert.equal(h.values.get('file1'), 'zip');
  assert.equal(outcome, 'pending', 'file ACK alone must not finish the engine lifecycle');
  index(); await saving; await flushing;
  assert.equal(h.values.get('global'), 'index'); assert.equal(outcome, 'success');
});
test('engine failures remain sticky by save key, retry restores flush, and originals retain return/throw/this', async () => {
  const api = freshAdapter(); let fail = true, returned, calls = 0;
  const failure = Error('compression failed');
  const storage = {tag: 7, saveObject(name) {
    assert.equal(this.tag, 7); calls++;
    returned = fail ? Promise.reject(failure) : Promise.resolve(name);
    return returned;
  }};
  const load = () => Promise.reject(Error('unused load failure'));
  storage.loadObject = load;
  const config = {save() { if (fail) throw failure; return 19; }};
  api.trackMZEngine(storage, null, config); api.trackMZEngine(storage, null, config);
  const saving = storage.saveObject('file1'); assert.equal(saving, returned);
  await assert.rejects(saving, error => error === failure); await assert.rejects(api.flush(), error => error === failure);
  fail = false; await storage.saveObject('other'); await assert.rejects(api.flush());
  assert.equal(await storage.saveObject('file1'), 'file1'); await api.flush();
  fail = true; assert.throws(() => config.save(), error => error === failure); await assert.rejects(api.flush());
  fail = false; assert.equal(config.save(), 19); await api.flush();
  assert.equal(calls, 3); assert.equal(storage.loadObject, load);
});
test('tracked fire-and-forget config saves, removals and event-turn continuations drain before flush', async () => {
  const api = freshAdapter(), h = host(); let release;
  const gate = new Promise(resolve => { release = resolve; });
  const local = api.install(original(), body => h.send(body));
  const storage = {saveToForage(key, value) { return gate.then(() => local.setItem(key, value)); }, removeForage(key) { return gate.then(() => local.removeItem(key)); }};
  const config = {save() { storage.saveToForage('config', 'settings'); }};
  api.trackMZEngine(storage, {}, config);
  assert.equal(config.save(), undefined);
  let done = false; const flushing = api.flush().then(() => { done = true; });
  await turn(); assert.equal(done, false); release(); await flushing;
  assert.equal(h.values.get('config'), 'settings');
  const removing = storage.removeForage('config'); await api.flush(); await removing;
  assert.equal(h.values.has('config'), false);
  const saving = local.setItem('temp', 'zip').then(() => new Promise(resolve => setTimeout(() => resolve(local.setItem('file1', 'zip')), 0)));
  await api.flush();
  assert.equal(h.values.get('file1'), 'zip');
  await saving;
});
test('global index rejection blocks flush until a full same-slot engine retry succeeds', async () => {
  const api = freshAdapter(), h = host(); let releaseGlobal, failGlobal = true, outcome = 'pending';
  const local = api.install(original(), body => {
    if (body.op === 'set' && body.key === 'global' && failGlobal) return new Promise((_, reject) => { releaseGlobal = () => reject(Error('global ACK failed')); });
    return h.send(body);
  });
  const storage = {saveObject(key, value) { return local.setItem(key, value); }};
  const data = {
    // The real API may return void from saveGlobalInfo. Its nested saveObject
    // must remain observable even after the saveGame promise has resolved.
    saveGlobalInfo() { storage.saveObject('global', 'index').catch(() => {}); },
    saveGame(id) { return storage.saveObject('file' + id, 'zip').then(() => this.saveGlobalInfo()); }
  };
  api.trackMZEngine(storage, data, {});
  const saving = data.saveGame(1);
  const flushing = api.flush().then(() => { outcome = 'success'; }, error => { outcome = error.message; });
  await turn(); await saving;
  assert.equal(h.values.get('file1'), 'zip'); assert.equal(outcome, 'pending');
  releaseGlobal(); await flushing; assert.equal(outcome, 'global ACK failed');
  await assert.rejects(api.flush(), /global ACK failed/);
  failGlobal = false; await data.saveGame(1); await api.flush();
  assert.equal(h.values.get('global'), 'index');
});
test('later engine failure survives an older success and a newer retry clears it', async () => {
  const api = freshAdapter(); let oldSuccess, newerFailure;
  let invocation = 0;
  const storage = {saveZip() {
    invocation++;
    if (invocation === 1) return new Promise(resolve => { oldSuccess = resolve; });
    if (invocation === 2) return new Promise((_, reject) => { newerFailure = reject; });
    return Promise.resolve('retry');
  }};
  api.trackMZEngine(storage);
  const older = storage.saveZip('file1');
  const newer = storage.saveZip('file1');
  const observed = newer.catch(() => {});
  newerFailure(Error('newer save failed')); await observed; oldSuccess('older'); await older;
  await assert.rejects(api.flush(), /newer save failed/);
  await storage.saveZip('file1'); await api.flush();
});

test('older nested config-save success cannot erase a newer same-key engine failure', async () => {
  const api = freshAdapter(), h = host();
  const local = api.install(original(), body => h.send(body));
  const newerFailure = Error('newer config compression failed');
  let releaseOldCompression;
  const oldCompression = new Promise(resolve => { releaseOldCompression = resolve; });
  const saves = [];
  const storage = {
    saveObject(key, value) {
      if (value === 'old') return oldCompression.then(() => this.saveZip(key, value));
      if (value === 'new') return Promise.reject(newerFailure);
      return Promise.resolve().then(() => this.saveZip(key, value));
    },
    saveZip(key, value) { return this.saveToForage(key, value); },
    saveToForage(key, value) { return local.setItem(key, value); }
  };
  const config = {save(value) {
    const saving = storage.saveObject('config', value);
    saves.push(saving); saving.catch(() => {});
    // Real MZ configurations can return void; only the nested promise carries failure.
  }};
  api.trackMZEngine(storage, undefined, config);
  assert.equal(config.save('old'), undefined);
  assert.equal(config.save('new'), undefined);
  await assert.rejects(saves[1], error => error === newerFailure);
  releaseOldCompression();
  await saves[0];
  assert.equal(h.values.get('config'), 'old', 'the older nested write really completed');
  await assert.rejects(api.flush(), error => error === newerFailure,
    'a later-numbered child of the old save is not a successful retry of the newer root save');
  assert.equal(config.save('retry'), undefined);
  await saves[2];
  await api.flush();
  assert.equal(h.values.get('config'), 'retry');
});

test('successful nested write cannot hide failure of its enclosing engine save', async () => {
  const api = freshAdapter(), h = host();
  const local = api.install(original(), body => h.send(body));
  const enclosingFailure = Error('save finalization failed');
  let fail = true;
  const storage = {
    async saveObject(key, value) {
      await this.saveZip(key, value);
      if (fail) throw enclosingFailure;
      return value;
    },
    saveZip(key, value) { return local.setItem(key, value); }
  };
  api.trackMZEngine(storage);
  await assert.rejects(storage.saveObject('file1', 'first'), error => error === enclosingFailure);
  assert.equal(h.values.get('file1'), 'first');
  await assert.rejects(api.flush(), error => error === enclosingFailure);
  fail = false;
  assert.equal(await storage.saveObject('file1', 'retry'), 'retry');
  await api.flush();
  assert.equal(h.values.get('file1'), 'retry');
});

test('mixed-entry late old child success keeps newer direct saveZip failure until quiescent retry', async () => {
  const api = freshAdapter(), h = host();
  const local = api.install(original(), body => h.send(body));
  const newerFailure = Error('newer direct saveZip failed');
  let releaseOldCompression;
  const compression = new Promise(resolve => { releaseOldCompression = resolve; });
  const storage = {
    saveObject(key, value) { return compression.then(() => this.saveZip(key, value)); },
    saveZip(key, value) {
      if (value === 'new') return Promise.reject(newerFailure);
      return this.saveToForage(key, value);
    },
    saveToForage(key, value) { return local.setItem(key, value); }
  };
  api.trackMZEngine(storage);
  const old = storage.saveObject('config', 'old');
  await assert.rejects(storage.saveZip('config', 'new'), error => error === newerFailure);
  releaseOldCompression();
  await old;
  assert.equal(h.values.get('config'), 'old');
  await assert.rejects(api.flush(), error => error === newerFailure,
    'the old parent can only spawn an ambiguous child, not a proven new retry');
  await storage.saveObject('config', 'retry');
  await api.flush();
  assert.equal(h.values.get('config'), 'retry');
});
