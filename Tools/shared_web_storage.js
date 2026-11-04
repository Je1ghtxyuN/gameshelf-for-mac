(function (root, factory) {
  'use strict';
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.GameShelfSharedWebStorage = factory();
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  const DRIVER = 'gameshelfSharedMZ';
  const contexts = new Set(), installed = new WeakMap();
  const engineObjects = new WeakMap(), engineStates = new Set(), activeEngine = new Set();
  let tail = Promise.resolve();
  let revision = 0, attemptSequence = 0;
  let engineDepth = 0, recoverableThrough = 0;
  function enqueue(work) {
    revision++;
    const operation = tail.then(work);
    tail = operation.then(function () {}, function () {});
    return operation;
  }
  function string(value, limit, label) {
    if (typeof value !== 'string') throw new TypeError(label + ' must be a string');
    // Reject unpaired UTF-16 surrogates instead of silently replacing them in
    // the native UTF-8 bridge. Valid Unicode and embedded NUL remain lossless.
    let bytes = 0;
    for (let i = 0; i < value.length; i++) {
      const c = value.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff) {
        const next = value.charCodeAt(++i);
        if (!(next >= 0xdc00 && next <= 0xdfff)) throw new TypeError('Unpaired surrogate');
        bytes += 4;
      } else if (c >= 0xdc00 && c <= 0xdfff) throw new TypeError('Unpaired surrogate');
      else bytes += c < 128 ? 1 : c < 2048 ? 2 : 3;
      if (bytes > limit) throw new RangeError(label + ' exceeds storage limit');
    }
    return value;
  }
  function callback(promise, cb) {
    if (typeof cb === 'function') {
      // Observe both outcomes without creating an unhandled rejected child.
      promise.then(v => { try { cb(null, v); } catch (_) {} }, e => { try { cb(e); } catch (_) {} });
    }
    return promise;
  }
  async function send(context, body) {
    const reply = await context.send(body);
    if (!reply || !Object.prototype.hasOwnProperty.call(reply, 'value')) throw new Error('Invalid shared storage ACK');
    return reply.value;
  }
  function validKeys(value) {
    if (!Array.isArray(value) || value.length > 512) throw new Error('Invalid shared storage keys');
    const seen = new Set();
    value.forEach(k => { string(k, 1024, 'key'); if (seen.has(k)) throw new Error('Duplicate shared storage key'); seen.add(k); });
    return value;
  }
  function validValue(value) { return value === null ? null : string(value, 4 * 1024 * 1024, 'value'); }
  function facade(target, context) {
    target.INDEXEDDB = 'asyncStorage';
    target.LOCALSTORAGE = 'localStorageWrapper';
    target.WEBSQL = 'webSQLStorage';
    function read(work, cb) { context.used = true; return callback(enqueue(work), cb); }
    function mutation(op, key, value, cb) {
      return read(async function () {
        const failureKey = op === 'clear' ? context.clearKey : key;
        try {
          const body = { op: op };
          if (op !== 'clear') body.key = string(key, 1024, 'key');
          if (op === 'set') body.value = string(value, 4 * 1024 * 1024, 'value');
          await send(context, body);
          if (op === 'clear') context.failures.clear();
          else context.failures.delete(failureKey);
          return op === 'set' ? value : undefined;
        } catch (error) {
          context.failures.set(failureKey, error);
          throw error;
        }
      }, cb);
    }
    target.getItem = (key, cb) => read(async () => validValue(await send(context, { op: 'get', key: string(key, 1024, 'key') })), cb);
    target.setItem = (key, value, cb) => mutation('set', key, value, cb);
    target.removeItem = (key, cb) => mutation('remove', key, undefined, cb);
    target.clear = cb => mutation('clear', undefined, undefined, cb);
    target.keys = cb => read(async () => validKeys(await send(context, { op: 'keys' })), cb);
    target.length = cb => read(async () => validKeys(await send(context, { op: 'keys' })).length, cb);
    target.key = (index, cb) => read(async () => {
      if (!Number.isInteger(index) || index < 0) return null;
      const keys = validKeys(await send(context, { op: 'keys' }));
      return index < keys.length ? keys[index] : null;
    }, cb);
    target.iterate = (iterator, cb) => read(async () => {
      if (typeof iterator !== 'function') throw new TypeError('Iterator required');
      const keys = validKeys(await send(context, { op: 'keys' }));
      for (let i = 0; i < keys.length; i++) {
        const value = validValue(await send(context, { op: 'get', key: keys[i] }));
        const result = iterator(value, keys[i], i + 1);
        if (result && typeof result.then === 'function') throw new TypeError('Async iterators are unsupported');
        if (result !== undefined) return result;
      }
    }, cb);
    target.ready = cb => read(() => undefined, cb);
    // MZ selects INDEXEDDB, but this alias always uses the account host driver.
    target.supports = driver => driver === DRIVER || driver === 'asyncStorage';
    target.driver = () => DRIVER;
    target.setDriver = (drivers, cb, failure) => {
      const promise = enqueue(() => {
        if (!(Array.isArray(drivers) ? drivers : [drivers]).some(target.supports)) throw new Error('Unsupported shared storage driver');
      });
      if (typeof failure === 'function') promise.then(() => {}, e => { try { failure(e); } catch (_) {} });
      return callback(promise, cb);
    };
    target.config = options => {
      if (options === undefined) return Object.assign({}, context.config);
      if (typeof options === 'string') return context.config[options];
      if (!options || typeof options !== 'object' || Array.isArray(options)) throw new TypeError('Invalid storage configuration');
      for (const field of ['name', 'storeName']) {
        if (Object.prototype.hasOwnProperty.call(options, field) && (context.used || context.config[field] !== undefined) && options[field] !== context.config[field]) {
          throw new Error('Changing shared MZ storage namespace is unsupported');
        }
      }
      Object.assign(context.config, options);
      return true;
    };
    target.createInstance = options => {
      // The bridge intentionally has one managed MZ store, not arbitrary
      // IndexedDB databases. Never merge an independently named database.
      if (options !== undefined) {
        if (!options || typeof options !== 'object') throw new TypeError('Invalid storage configuration');
        for (const field of ['name', 'storeName']) {
          if (Object.prototype.hasOwnProperty.call(options, field) && options[field] !== context.config[field]) throw new Error('Different shared MZ storage namespace is unsupported');
        }
        target.config(options);
      }
      return facade(Object.create(null), context);
    };
    return target;
  }
  function install(target, sendAsync) {
    if (!target || (typeof target !== 'object' && typeof target !== 'function') || typeof sendAsync !== 'function') throw new TypeError('Storage target and host sender required');
    if (installed.has(target)) {
      if (installed.get(target).send !== sendAsync) throw new Error('Cannot rebind shared storage account');
      return target;
    }
    const context = { send: sendAsync, failures: new Map(), clearKey: Symbol('clear'), config: Object.create(null), used: false };
    contexts.add(context);
    facade(target, context);
    installed.set(target, context);
    return target;
  }
  function engineCompletion(state, key, attempt, recoverBefore, failed, error) {
    const success = state.successes.get(key) || 0, previous = state.failures.get(key);
    if (failed) {
      // A success may supersede only failures predating its whole quiescent
      // batch. A delayed old chain's child is not a proven new logical retry.
      if (attempt > success && (!previous || attempt >= previous.attempt)) state.failures.set(key, {attempt, error});
    } else {
      state.successes.set(key, Math.max(success, recoverBefore));
      if (previous && previous.attempt <= recoverBefore) state.failures.delete(key);
    }
    revision++;
  }
  function wrapEngine(object, methods, keyFor) {
    if (!object || (typeof object !== 'object' && typeof object !== 'function')) return;
    let state = engineObjects.get(object);
    if (!state) {
      state = {wrappers: new Map(), lifecycles: new Map(), unknownKey: Symbol('save')};
      engineObjects.set(object, state);
    }
    for (const method of methods) {
      const original = object[method];
      if (typeof original !== 'function' || state.wrappers.get(method) === original) continue;
      let lifecycle = state.lifecycles.get(method);
      if (!lifecycle) {
        lifecycle = {failures: new Map(), successes: new Map()};
        state.lifecycles.set(method, lifecycle); engineStates.add(lifecycle);
      }
      const wrapped = function (...args) {
        const key = keyFor(method, args, state), attempt = ++attemptSequence;
        // Browser promises do not reveal their asynchronous caller. Treat all
        // overlapping engine work conservatively as one batch, across methods
        // and manager objects. Only a new entry after complete quiescence can
        // grant its descendants credit to clear older failures.
        if (engineDepth === 0 && activeEngine.size === 0) recoverableThrough = attempt - 1;
        const recoverBefore = recoverableThrough;
        revision++;
        engineDepth++;
        try {
          let result;
          try { result = Reflect.apply(original, this, args); }
          catch (error) { engineCompletion(lifecycle, key, attempt, recoverBefore, true, error); throw error; }
          let then;
          try { then = result == null ? undefined : result.then; }
          catch (error) {
            // Preserve even an unusual original return object/getter unchanged.
            engineCompletion(lifecycle, key, attempt, recoverBefore, true, error); return result;
          }
          if (typeof then === 'function') {
            let observed;
            const finish = (failed, error) => {
              engineCompletion(lifecycle, key, attempt, recoverBefore, failed, error);
              activeEngine.delete(observed);
            };
            observed = Promise.resolve(result).then(() => finish(false), error => finish(true, error));
            activeEngine.add(observed);
          } else engineCompletion(lifecycle, key, attempt, recoverBefore, false);
          // Observing a promise must not replace it or turn synchronous throws
          // into rejections. Nested engine methods are independently observed.
          return result;
        } finally {
          engineDepth--;
        }
      };
      object[method] = wrapped;
      state.wrappers.set(method, wrapped);
    }
  }
  function trackMZEngine(storageManager, dataManager, configManager) {
    const name = (args, state) => typeof args[0] === 'string' || typeof args[0] === 'number' ? String(args[0]) : state.unknownKey;
    wrapEngine(storageManager, ['saveObject', 'saveZip', 'saveToForage', 'removeForage', 'remove', 'saveToLocalFile', 'removeLocalFile'], (_, args, state) => name(args, state));
    wrapEngine(dataManager, ['saveGame', 'saveGlobalInfo'], (method, args, state) => method === 'saveGlobalInfo' ? 'global' : name(args, state));
    // Some MZ versions return void here while calling saveObject internally;
    // that nested promise is still tracked by the StorageManager wrapper.
    wrapEngine(configManager, ['save'], () => 'config');
  }
  async function flush() {
    // Stop new engine work before calling. Drain dynamically: a completed ACK
    // or save promise can enqueue another write or start another tracked save.
    // One event turn also admits already-scheduled continuation work. Arbitrary
    // future timers are not covered unless part of an active tracked lifecycle.
    for (;;) {
      const before = revision, barrier = tail;
      await barrier;
      await Promise.all(Array.from(activeEngine));
      await Promise.resolve();
      await new Promise(resolve => setTimeout(resolve, 0));
      if (before !== revision || barrier !== tail || activeEngine.size !== 0) continue;
      for (const context of contexts) {
        for (const error of context.failures.values()) throw error;
      }
      for (const state of engineStates) {
        for (const failure of state.failures.values()) throw failure.error;
      }
      return;
    }
  }
  return Object.freeze({ install: install, flush: flush, trackMZEngine: trackMZEngine });
});
