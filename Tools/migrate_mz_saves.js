/* RPG Maker MZ ZIP migration. The caller must exclude concurrent saves/migrations
 * for this game until the returned promise settles. No receipt is persisted.
 * Names are logical StorageManager names (global/fileN), without extensions.
 * Slot 0 (MZ autosave) is supported; conflict allocation uses manual slots 1..999.
 * io.unzip must return decoded MZ contents (including JsonEx decoding if needed).
 * io.remove must be idempotent when a key is absent.
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else if (typeof define === 'function' && define.amd) define([], factory);
  else root.GameShelfMZSaveMigration = factory();
}(typeof window !== 'undefined' ? window : globalThis, function () {
  'use strict';

  const own = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
  const record = value => value !== null && typeof value === 'object' && !Array.isArray(value);
  const slotNumber = name => /^file(?:0|[1-9][0-9]{0,2})$/.test(name) ? Number(name.slice(4)) : null;
  const knownName = name => ['global', 'config', 'titleInfo'].includes(name) || slotNumber(name) !== null;
  const message = error => error instanceof Error ? error.message : String(error);

  function identity(plan, io) {
    if (!plan || !io || !Number.isSafeInteger(plan.gameId) || plan.gameId < 0 || plan.gameId !== io.gameId) {
      throw new Error('MZ migration: invalid or mismatched gameId');
    }
  }

  function validInfo(value) {
    const images = list => Array.isArray(list) && list.every(pair =>
      Array.isArray(pair) && pair.length === 2 && typeof pair[0] === 'string' &&
      Number.isInteger(pair[1]) && pair[1] >= 0 && pair[1] <= 7);
    return record(value) && ['title', 'characters', 'faces', 'playtime', 'timestamp'].every(key => own(value, key)) &&
      typeof value.title === 'string' && images(value.characters) && images(value.faces) &&
      typeof value.playtime === 'string' && /^\d+:[0-5]\d:[0-5]\d$/.test(value.playtime) &&
      Number.isFinite(value.timestamp) && value.timestamp >= 0;
  }

  function validateGlobal(value, label) {
    if (!Array.isArray(value) || value.length > 1000 ||
        Object.keys(value).some(key => !/^(?:0|[1-9][0-9]{0,2})$/.test(key))) {
      throw new Error('MZ migration: invalid ' + label + ' global array');
    }
    for (let slot = 0; slot < value.length; slot++) {
      if (value[slot] != null && !validInfo(value[slot])) {
        throw new Error('MZ migration: invalid ' + label + ' global info at slot ' + slot);
      }
    }
    return value;
  }

  async function decode(io, zipped, label) {
    if (typeof zipped !== 'string' || !zipped.length) throw new Error('MZ migration: invalid ZIP for ' + label);
    try { return await io.unzip(zipped); }
    catch (cause) { throw new Error('MZ migration: cannot unzip ' + label + ': ' + message(cause)); }
  }

  async function validateSave(io, zipped, label) {
    const value = await decode(io, zipped, label);
    if (!record(value) || !['system', 'party', 'map', 'player'].every(key => own(value, key) && record(value[key]))) {
      throw new Error('MZ migration: invalid save contents for ' + label);
    }
  }

  async function migrate(plan, io) {
    identity(plan, io);
    for (const method of ['read', 'write', 'remove', 'names', 'unzip', 'zip']) {
      if (typeof io[method] !== 'function') throw new Error('MZ migration: missing io.' + method);
    }
    if (!record(plan.files) || !own(plan.files, 'global')) throw new Error('MZ migration: source global is required');
    // Capture input strings before yielding; no subsequent access to mutable plan.files.
    const files = new Map(Object.entries(plan.files));
    if ([...files.keys()].some(name => !knownName(name))) throw new Error('MZ migration: unknown source file name');
    const sourceGlobal = validateGlobal(await decode(io, files.get('global'), 'source global'), 'source');
    const sourceSlots = [...files.keys()].map(slotNumber).filter(slot => slot !== null).sort((a, b) => a - b);
    if (!sourceSlots.length) throw new Error('MZ migration: source has no save slots');
    for (const slot of sourceSlots) {
      if (!validInfo(sourceGlobal[slot])) throw new Error('MZ migration: source file' + slot + ' has no valid global info');
      await validateSave(io, files.get('file' + slot), 'source file' + slot);
    }
    for (let slot = 0; slot < sourceGlobal.length; slot++) {
      if (sourceGlobal[slot] != null && !files.has('file' + slot)) {
        throw new Error('MZ migration: source global references missing file' + slot);
      }
    }

    const names = await io.names();
    if (!Array.isArray(names) || names.some(name => typeof name !== 'string' || !knownName(name)) ||
        new Set(names).size !== names.length) throw new Error('MZ migration: invalid or unknown target names');
    const oldGlobalZip = await io.read('global');
    if (oldGlobalZip === null && names.includes('global')) throw new Error('MZ migration: target global disappeared');
    const targetGlobal = oldGlobalZip === null ? [] : validateGlobal(await decode(io, oldGlobalZip, 'target global'), 'target');
    const targetSlots = names.map(slotNumber).filter(slot => slot !== null).sort((a, b) => a - b);
    const payloads = new Map();
    const occupied = new Set();
    for (let slot = 0; slot < targetGlobal.length; slot++) {
      if (targetGlobal[slot] != null) occupied.add(slot);
    }
    for (const slot of targetSlots) {
      const zipped = await io.read('file' + slot);
      await validateSave(io, zipped, 'target file' + slot);
      occupied.add(slot);
      // Stable lowest-slot choice when the target already contains duplicate ZIPs.
      if (!payloads.has(zipped)) payloads.set(zipped, slot);
    }

    const merged = targetGlobal.slice();
    const additions = [];
    const mappings = [];
    let reused = 0;
    let globalChanged = false;
    for (const from of sourceSlots) {
      const zipped = files.get('file' + from);
      let to = payloads.get(zipped);
      if (to !== undefined) reused++;
      else {
        to = from;
        if (occupied.has(to)) {
          to = 1;
          while (to <= 999 && occupied.has(to)) to++;
          if (to > 999) throw new Error('MZ migration: no free save slot in 1..999');
        }
        occupied.add(to);
        payloads.set(zipped, to);
        additions.push({ name: 'file' + to, zipped });
      }
      if (merged[to] == null) {
        merged[to] = sourceGlobal[from];
        globalChanged = true;
      }
      mappings.push({ from, to });
    }

    // Compression and all validation finish before the first persistent mutation.
    const newGlobalZip = globalChanged ? await io.zip(merged) : null;
    if (globalChanged && (typeof newGlobalZip !== 'string' || !newGlobalZip.length)) {
      throw new Error('MZ migration: zip returned invalid global ZIP');
    }
    identity(plan, io);
    const attempted = [];
    let globalAttempted = false;
    try {
      for (const addition of additions) {
        // A rejected write may already have committed; record intent before await.
        attempted.push(addition.name);
        await io.write(addition.name, addition.zipped);
      }
      if (globalChanged) {
        globalAttempted = true;
        await io.write('global', newGlobalZip);
      }
    } catch (cause) {
      const rollbackErrors = [];
      if (globalAttempted) {
        try {
          if (oldGlobalZip === null) await io.remove('global');
          else await io.write('global', oldGlobalZip);
        } catch (error) { rollbackErrors.push({ name: 'global', error }); }
      }
      for (const name of attempted.reverse()) {
        try { await io.remove(name); }
        catch (error) { rollbackErrors.push({ name, error }); }
      }
      if (rollbackErrors.length) {
        const error = new Error('MZ migration failed: ' + message(cause) + '; rollback failed: ' +
          rollbackErrors.map(item => item.name + ': ' + message(item.error)).join('; '));
        error.cause = cause;
        error.rollbackErrors = rollbackErrors;
        throw error;
      }
      throw cause;
    }
    return { imported: additions.length, reused, mappings };
  }

  return { migrate };
}));
