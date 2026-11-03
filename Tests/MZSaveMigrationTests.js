'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { deflateSync, inflateSync } = require('node:zlib');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const modulePath = path.join(__dirname, '../Tools/migrate_mz_saves.js');
// Missing production code is an assertion failure in RED, not a loader error.
const migration = fs.existsSync(modulePath) ? require(modulePath) : {};
async function migrate(plan, io) {
  assert.equal(typeof migration.migrate, 'function', 'migration API has not been implemented');
  return migration.migrate(plan, io);
}

const zip = value => deflateSync(JSON.stringify(value)).toString('base64');
const unzip = value => JSON.parse(inflateSync(Buffer.from(value, 'base64')).toString());
const info = (playtime = '2:39:34', timestamp = 1700000000000) => ({
  title: 'Sakura', characters: [['Actor1', 0]], faces: [['Actor1', 0]], playtime, timestamp
});
const save = level => ({ system: { versionId: 1 }, party: { level }, map: { mapId: 4 }, player: { x: 2, y: 3 } });
const source = () => ({ gameId: 123456, files: {
  global: zip([null, info(), info('1:09:41', 1700000001000)]),
  file1: zip(save(17)), file2: zip(save(7)), config: 'ignored config ZIP', titleInfo: 'ignored title ZIP'
} });

function storage(initial = {}, fault = () => {}) {
  const data = new Map(Object.entries(initial));
  const mutations = [];
  const io = {
    gameId: 123456,
    async names() { return [...data.keys()]; },
    async read(name) { return data.has(name) ? data.get(name) : null; },
    async write(name, value) {
      mutations.push(['write', name]);
      await fault('beforeWrite', name, value);
      data.set(name, value);
      await fault('afterWrite', name, value);
    },
    async remove(name) {
      mutations.push(['remove', name]);
      await fault('beforeRemove', name);
      data.delete(name);
    },
    async zip(value) { return zip(value); },
    async unzip(value) { return unzip(value); }
  };
  return { io, data, mutations };
}
function snapshot(s) { return [...s.data.entries()].sort(([a], [b]) => a.localeCompare(b)); }
async function unchangedFailure(plan, s) {
  const before = snapshot(s);
  await assert.rejects(migrate(plan, s.io), error => {
    assert.notEqual(error.code, 'ERR_ASSERTION', 'missing API must not masquerade as validation');
    return true;
  });
  assert.deepEqual(snapshot(s), before);
  assert.deepEqual(s.mutations, [], 'validation must finish before any mutation');
}

test('empty target restores both real progress slots and preserves config/titleInfo', async () => {
  const p = source();
  const s = storage({ config: 'current config', titleInfo: 'current title' });
  assert.deepEqual(await migrate(p, s.io), { imported: 2, reused: 0, mappings: [{ from: 1, to: 1 }, { from: 2, to: 2 }] });
  assert.equal(s.data.get('file1'), p.files.file1);
  assert.equal(s.data.get('file2'), p.files.file2);
  assert.equal(unzip(s.data.get('file1')).party.level, 17);
  assert.equal(unzip(s.data.get('file2')).party.level, 7);
  assert.equal(unzip(s.data.get('global'))[1].playtime, '2:39:34');
  assert.equal(unzip(s.data.get('global'))[2].playtime, '1:09:41');
  assert.equal(s.data.get('config'), 'current config');
  assert.equal(s.data.get('titleInfo'), 'current title');
  assert.ok(s.mutations.every(([, name]) => !['config', 'titleInfo'].includes(name)));
});

test('conflicts allocate first free slot, preserve metadata, and repeat is a write-free no-op', async () => {
  const existingInfo = { ...info('8:00:00'), plugin: { keep: true } };
  const s = storage({ global: zip([null, existingInfo]), file1: zip(save(99)), config: 'keep' });
  const originalSlot = s.data.get('file1');
  const p = source();
  assert.deepEqual(await migrate(p, s.io), { imported: 2, reused: 0, mappings: [{ from: 1, to: 2 }, { from: 2, to: 3 }] });
  assert.equal(s.data.get('file1'), originalSlot);
  assert.deepEqual(unzip(s.data.get('global'))[1], existingInfo);
  assert.deepEqual(unzip(s.data.get('global'))[2], info());
  const before = snapshot(s);
  s.mutations.length = 0;
  assert.deepEqual(await migrate(p, s.io), { imported: 0, reused: 2, mappings: [{ from: 1, to: 2 }, { from: 2, to: 3 }] });
  assert.deepEqual(snapshot(s), before);
  assert.deepEqual(s.mutations, []);
});

test('identical ZIP anywhere is reused and only missing metadata is filled', async () => {
  const p = source();
  const keepInfo = info('9:00:00');
  const s = storage({ file5: p.files.file1, file9: p.files.file2, global: zip([null, null, null, null, null, keepInfo]) });
  assert.deepEqual(await migrate(p, s.io), { imported: 0, reused: 2, mappings: [{ from: 1, to: 5 }, { from: 2, to: 9 }] });
  assert.deepEqual(unzip(s.data.get('global'))[5], keepInfo);
  assert.deepEqual(unzip(s.data.get('global'))[9], info('1:09:41', 1700000001000));
  assert.deepEqual(s.mutations, [['write', 'global']]);
});

test('identical source payloads share one destination slot', async () => {
  const p = source(); p.files.file2 = p.files.file1;
  const s = storage();
  assert.deepEqual(await migrate(p, s.io), { imported: 1, reused: 1, mappings: [{ from: 1, to: 1 }, { from: 2, to: 1 }] });
  assert.deepEqual(unzip(s.data.get('global'))[1], info());
  assert.equal(s.data.has('file2'), false);
});

test('slot metadata without a file is reserved rather than overwritten', async () => {
  const old = info('6:00:00');
  const s = storage({ global: zip([null, old]) });
  await migrate(source(), s.io);
  assert.deepEqual(unzip(s.data.get('global'))[1], old);
  assert.equal(s.data.has('file1'), false);
  assert.equal(unzip(s.data.get('file2')).party.level, 17);
});

test('all corrupt/unknown source formats fail before any write', async () => {
  const variants = [
    p => { p.files.global = 'bad ZIP'; },
    p => { p.files.global = zip({}); },
    p => { p.files.file2 = 'bad ZIP'; },
    p => { p.files.file2 = zip({}); },
    p => { p.files.file2 = zip({ system: {}, party: {}, map: {} }); },
    p => { p.files.file2 = zip({ system: {}, party: null, map: {}, player: {} }); },
    p => { p.files.global = zip([null, info(), {}]); },
    p => { p.files.global = zip([null, info(), { ...info(), timestamp: 'bad' }]); },
    p => { p.files.global = zip([null, info(), { ...info(), characters: [['Actor', -1]] }]); },
    p => { p.files.global = zip([null, info()]); },
    p => { delete p.files.file2; },
    p => { p.files.file01 = p.files.file1; },
    p => { p.files.file1000 = p.files.file1; },
    p => { p.files.unknown = 'opaque'; }
  ];
  for (const mutate of variants) { const p = source(); mutate(p); await unchangedFailure(p, storage({ config: 'keep' })); }
});

test('corrupt target index or any target save fails before mutation', async () => {
  for (const initial of [
    { global: 'bad ZIP' }, { global: zip({}) }, { global: zip([null, {}]) },
    { file8: 'bad ZIP' }, { file8: zip({}) }, { file8: zip([]) }
  ]) await unchangedFailure(source(), storage(initial));
});

test('game ID mismatch and invalid identity fail without writing', async () => {
  for (const id of [42, '123456', NaN, null, undefined]) {
    const p = source(); p.gameId = id;
    await unchangedFailure(p, storage());
  }
  const s = storage(); s.io.gameId = '123456';
  await unchangedFailure(source(), s);
});

for (const afterWrite of [false, true]) {
  test(`second slot write ${afterWrite ? 'mutates then rejects' : 'rejects'}: remove all attempted new slots`, async () => {
    const s = storage({ config: 'keep', global: zip([]) }, (phase, name) => {
      if (name === 'file2' && phase === (afterWrite ? 'afterWrite' : 'beforeWrite')) throw new Error('second slot failed');
    });
    const before = snapshot(s);
    await assert.rejects(migrate(source(), s.io), /second slot failed/);
    assert.deepEqual(snapshot(s), before);
    assert.ok(s.mutations.some(([op, name]) => op === 'remove' && name === 'file1'));
  });
}

for (const existingGlobal of [false, true]) {
  test(`global writes then rejects: restore ${existingGlobal ? 'exact prior ZIP' : 'absence'} and remove new slots`, async () => {
    let failed = false;
    const initial = { config: 'keep', file8: zip(save(88)) };
    if (existingGlobal) initial.global = zip([null, null, null, null, null, null, null, null, info('8:00:00')]);
    const s = storage(initial, (phase, name) => {
      if (!failed && phase === 'afterWrite' && name === 'global') { failed = true; throw new Error('global committed then rejected'); }
    });
    const before = snapshot(s);
    await assert.rejects(migrate(source(), s.io), /global committed then rejected/);
    assert.deepEqual(snapshot(s), before);
  });
}

test('rollback failure is explicit, retains cause, and attempts remaining cleanup', async () => {
  const s = storage({ global: zip([]) }, (phase, name) => {
    if (phase === 'afterWrite' && name === 'global') throw new Error('global write failed');
    if (phase === 'beforeRemove' && name === 'file2') throw new Error('cannot remove file2');
  });
  await assert.rejects(migrate(source(), s.io), error => {
    assert.match(error.message, /rollback/i);
    assert.match(error.message, /file2/);
    assert.match(error.message, /global/);
    assert.match(error.cause.message, /global write failed/);
    return true;
  });
  assert.equal(s.data.has('file1'), false, 'one cleanup failure must not stop the others');
});

test('no capacity rejects before writing even when earlier source slots would fit', async () => {
  // Only slot 1 is free: planning the first import must not persist it before
  // discovering that the second import has nowhere to go.
  const entries = { global: zip(Array.from({ length: 1000 }, (_, i) => i > 1 ? info('8:00:00') : null)) };
  await unchangedFailure(source(), storage(entries));
});

test('ZIP preparation failure does not write any slots', async () => {
  const s = storage(); s.io.zip = async () => { throw new Error('compression failed'); };
  await unchangedFailure(source(), s);
});

test('browser UMD exposes the same callable migration API', async () => {
  assert.ok(fs.existsSync(modulePath), 'browser module has not been implemented');
  const context = { window: {} };
  vm.runInNewContext(fs.readFileSync(modulePath, 'utf8'), context);
  assert.equal(typeof context.window.GameShelfMZSaveMigration.migrate, 'function');
  const s = storage();
  const result = await context.window.GameShelfMZSaveMigration.migrate(source(), s.io);
  assert.equal(result.imported, 2);
  assert.equal(s.data.get('file1'), source().files.file1);
});

test('source config/titleInfo are never imported when absent on target', async () => {
  const s = storage();
  await migrate(source(), s.io);
  assert.deepEqual([...s.data.keys()].sort(), ['file1', 'file2', 'global']);
});

test('equal objects with different ZIP bytes remain different progress payloads', async () => {
  const p = source();
  const differentZip = deflateSync(JSON.stringify(save(17)), { level: 0 }).toString('base64');
  assert.notEqual(differentZip, p.files.file1);
  const s = storage({ file1: differentZip, global: zip([null, info('8:00:00')]) });
  const result = await migrate(p, s.io);
  assert.equal(result.imported, 2);
  assert.equal(result.reused, 0);
  assert.equal(s.data.get('file1'), differentZip);
});

test('allocation reaches slot 999 but never writes beyond the bound', async () => {
  const p = source(); delete p.files.file2; p.files.global = zip([null, info()]);
  const index = Array.from({ length: 999 }, (_, i) => i ? info('8:00:00') : null);
  const s = storage({ global: zip(index) });
  assert.deepEqual(await migrate(p, s.io), { imported: 1, reused: 0, mappings: [{ from: 1, to: 999 }] });
  assert.equal(s.data.get('file999'), p.files.file1);
  assert.equal(s.data.has('file1000'), false);
});

test('MZ autosave slot zero is retained and conflicts move into a manual slot', async () => {
  const p = { gameId: 123456, files: { global: zip([info()]), file0: zip(save(17)) } };
  const empty = storage();
  assert.deepEqual(await migrate(p, empty.io), { imported: 1, reused: 0, mappings: [{ from: 0, to: 0 }] });
  const s = storage({ file0: zip(save(99)), global: zip([info('9:00:00')]) });
  const old = s.data.get('file0');
  assert.deepEqual(await migrate(p, s.io), { imported: 1, reused: 0, mappings: [{ from: 0, to: 1 }] });
  assert.equal(s.data.get('file0'), old);
});

test('late target read rejection and disappearing slot fail before mutation', async () => {
  for (const replacement of [async () => { throw new Error('read failed'); }, async () => null]) {
    const s = storage({ file9: zip(save(99)) });
    const read = s.io.read;
    s.io.read = async name => name === 'file9' ? replacement() : read(name);
    await unchangedFailure(source(), s);
  }
});

test('identity changed during async preflight cannot receive writes', async () => {
  const s = storage();
  const compress = s.io.zip;
  s.io.zip = async value => { s.io.gameId = 999; return compress(value); };
  await unchangedFailure(source(), s);
});
