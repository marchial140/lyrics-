import test from 'node:test';
import assert from 'node:assert/strict';
import { randomBytes, randomUUID, generateKeyPairSync, verify } from 'node:crypto';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Store } from '../src/store.mjs';
import { Worker } from '../src/worker.mjs';
import { contentFor, parseLRC, makePayload, Apns, RemoteError } from '../src/services.mjs';
import { server } from '../src/http.mjs';

function fixture() {
  let clock = 1000000;
  const store = new Store(':memory:', randomBytes(32).toString('base64'));
  const id = randomUUID(); const secret = randomBytes(32).toString('base64url');
  const tokens = { clientID: 'test-client', accessToken: 'access-token-original', refreshToken: 'refresh-token-original', expiresAt: new Date(clock + 3600000).toISOString() };
  const sample = { is_playing: true, progress_ms: 0, item: { id: 'one', type: 'track', name: 'Original demo', artists: [{ name: 'Demo author' }], duration_ms: 30000 } };
  const pushes = []; let refreshes = 0; let polls = 0;
  const spotify = {
    async playback() { polls++; return structuredClone(sample); },
    async refresh(t) { refreshes++; return { ...t, accessToken: 'renewed-access', refreshToken: 'renewed-refresh', expiresAt: new Date(clock + 3600000).toISOString() }; }
  };
  const apns = { async send(s, state, event, timestamp) { pushes.push({ token: s.pushToken, state: structuredClone(state), event, timestamp }); } };
  const lyrics = { async load() { return { lines: parseLRC('[00:00]First original line\n[00:06]Second original line') }; } };
  const worker = new Worker({ store, spotify, lyrics, apns, now: () => clock });
  const session = { tokens, expires: clock + 21600000, nextPoll: 0, pushToken: 'ab'.repeat(32), frequent: true, activityVersion: 1 };
  store.create(id, secret, session);
  return { store, worker, id, secret, tokens, sample, pushes, spotify, apns, now: () => clock,
    advance: ms => { clock += ms; }, stats: () => ({ refreshes, polls }) };
}

test('LRC boundaries, repeated tags, empty interlude and backward seek', () => {
  const lines = parseLRC('[ar:Demo]\n[00:05][00:10.25]Original\n[00:08]\n[00:99]invalid');
  assert.deepEqual(lines.map(x => x.time), [5, 8, 10.25]);
  const playback = { is_playing: true, item: { type: 'track', name: 'Demo', artists: [] } };
  assert.equal(contentFor(playback, { lines }, 4).line, '♪');
  assert.equal(contentFor(playback, { lines }, 5).line, 'Original');
  assert.equal(contentFor(playback, { lines }, 9).line, '♪');
  assert.equal(contentFor(playback, { lines }, 10.25).lineNumber, 3);
  assert.equal(contentFor(playback, { lines }, 5).lineNumber, 1);
});

test('encrypted SQLite survives restart and secrets are absent from disk', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lyriclive-')); const path = join(dir, 'data.sqlite');
  const key = randomBytes(32).toString('base64');
  let store = new Store(path, key);
  store.create('record', 'capability-secret', { refreshToken: 'sensitive-refresh-value' }); store.close();
  assert.equal(readFileSync(path).includes(Buffer.from('sensitive-refresh-value')), false);
  assert.equal(readFileSync(path).includes(Buffer.from('capability-secret')), false);
  store = new Store(path, key);
  assert.equal(store.get('record').refreshToken, 'sensitive-refresh-value');
  assert.equal(store.authorized('record', 'wrong'), false);
  store.close(); rmSync(dir, { recursive: true, force: true });
});

test('server advances lyrics without any iPhone requests', async t => {
  const f = fixture(); t.after(() => f.store.close());
  await f.worker.runOnce(); f.advance(6500); f.sample.progress_ms = 6500; await f.worker.runOnce();
  assert.equal(f.pushes[0].state.line, 'First original line');
  assert.equal(f.pushes.at(-1).state.line, 'Second original line');
  assert.ok(f.pushes[1].timestamp > f.pushes[0].timestamp);
});

test('pause, backward seek and track change use new dynamic title', async t => {
  const f = fixture(); t.after(() => f.store.close());
  f.sample.progress_ms = 9000; await f.worker.runOnce();
  f.advance(4000); f.sample.progress_ms = 1000; f.sample.is_playing = false; await f.worker.runOnce();
  assert.equal(f.pushes.at(-1).state.lineNumber, 1);
  assert.equal(f.pushes.at(-1).state.isPlaying, false);
  f.advance(4000); f.sample.item.id = 'two'; f.sample.item.name = 'Another demo'; await f.worker.runOnce();
  assert.equal(f.pushes.at(-1).state.trackTitle, 'Another demo');
});

test('refresh is saved before polling and preserved through stop', async t => {
  const f = fixture(); t.after(() => f.store.close());
  const s = f.store.get(f.id); s.tokens.expiresAt = new Date(f.now()).toISOString(); f.store.save(f.id, s);
  await f.worker.runOnce();
  assert.equal(f.stats().refreshes, 1);
  assert.equal(f.store.get(f.id).tokens.refreshToken, 'renewed-refresh');
  const restored = await f.worker.stop(f.id);
  assert.equal(restored.refreshToken, 'renewed-refresh');
  assert.equal(f.store.get(f.id), null);
  assert.equal(f.pushes.at(-1).event, 'end');
});

test('Spotify Retry-After survives a worker restart', async t => {
  const f = fixture(); t.after(() => f.store.close());
  f.spotify.playback = async () => { throw new RemoteError(429, 60); };
  await f.worker.runOnce(); assert.equal(f.store.get(f.id).nextPoll, f.now() + 60000);
  let count = 0; f.spotify.playback = async () => { count++; return f.sample; };
  f.worker.runtime.clear(); f.advance(1000); await f.worker.runOnce();
  assert.equal(count, 0);
});

test('APNs 429 backs off without deleting Spotify credentials', async t => {
  const f = fixture(); t.after(() => f.store.close()); let attempts = 0;
  f.apns.send = async () => { attempts++; throw Object.assign(new RemoteError(429, 60), { origin: 'apns' }); };
  await f.worker.runOnce(); f.advance(5000); await f.worker.runOnce();
  assert.equal(attempts, 1); assert.ok(f.store.get(f.id).tokens);
});

test('APNs 410 drops expired device token, not the session', async t => {
  const f = fixture(); t.after(() => f.store.close());
  f.apns.send = async () => { throw Object.assign(new RemoteError(410), { origin: 'apns' }); };
  await f.worker.runOnce(); assert.equal(f.store.get(f.id).pushToken, null); assert.ok(f.store.get(f.id).tokens);
});

test('session expiration deletes stored tokens even if Apple is unreachable', async t => {
  const f = fixture(); t.after(() => f.store.close());
  f.apns.send = async () => { throw new Error('offline'); };
  f.advance(21600001); await f.worker.runOnce(); assert.equal(f.store.get(f.id), null);
});

test('HTTP capability isolation, stale registration and token handoff', async t => {
  const f = fixture(); t.after(() => f.store.close());
  const app = server({ ...f, clientID: 'test-client', now: f.now });
  await new Promise(resolve => app.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => app.close(resolve)));
  const base = `http://127.0.0.1:${app.address().port}/v1/sessions/${f.id}`;
  const call = (method, suffix = '', body, secret = f.secret) => fetch(base + suffix, { method, headers: { authorization: `Bearer ${secret}`, 'content-type': 'application/json' }, body: body && JSON.stringify(body) });
  assert.equal((await call('GET', '/playback', null, randomBytes(32).toString('base64url'))).status, 401);
  assert.equal((await call('PUT', '/activity', { pushToken: 'cd'.repeat(32), version: 2, activityID: 'new', frequent: false })).status, 200);
  assert.equal((await call('PUT', '/activity', { pushToken: 'ef'.repeat(32), version: 1, activityID: 'old' })).status, 409);
  assert.equal(f.store.get(f.id).pushToken, 'cd'.repeat(32));
  assert.equal((await call('DELETE', '/activity', { version: 3 })).status, 200);
  assert.equal((await call('PUT', '/activity', { pushToken: 'ef'.repeat(32), version: 2, activityID: 'new' })).status, 409);
  const s = f.store.get(f.id); s.tokens.refreshToken = 'rotated-server-token'; f.store.save(f.id, s);
  await call('PUT', '', { tokens: f.tokens });
  assert.equal(f.store.get(f.id).tokens.refreshToken, 'rotated-server-token');
  const result = await (await call('DELETE')).json();
  assert.equal(result.tokens.refreshToken, 'rotated-server-token'); assert.equal(f.store.get(f.id), null);
});

test('APNs payload schema, expiration, absence of sound and 4KB guard', () => {
  const state = contentFor({ is_playing: true, item: { type: 'track', name: '😀'.repeat(500), artists: [] } }, { lines: [{ time: 0, text: '😀'.repeat(500) }] }, 1);
  const body = makePayload(state, 'update', 1000); const value = JSON.parse(body);
  assert.ok(Buffer.byteLength(body) <= 4096);
  assert.equal(value.aps['content-state'].trackTitle.length, 200);
  assert.equal(value.aps['stale-date'], 1030);
  assert.equal(value.aps.sound, undefined); assert.equal(value.aps.alert, undefined);
  assert.equal(JSON.parse(makePayload(state, 'end', 1000)).aps['dismissal-date'], 1000);
  assert.throws(() => makePayload({ line: 'x'.repeat(10000) }, 'update', 1000));
});

test('APNs ES256 signature has Apple-compatible raw R/S encoding', () => {
  const dir = mkdtempSync(join(tmpdir(), 'lyriclive-key-'));
  const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  const path = join(dir, 'test-key.pem'); writeFileSync(path, privateKey.export({ type: 'pkcs8', format: 'pem' }));
  const apns = new Apns({ teamID: 'AAAAAAAAAA', keyID: 'BBBBBBBBBB', bundleID: 'ca.demo.LyricLive', keyPath: path, environment: 'development' });
  const [header, claims, signature] = apns.jwt().split('.');
  assert.equal(Buffer.from(signature, 'base64url').length, 64);
  assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
  assert.equal(apns.topic, 'ca.demo.LyricLive.push-type.liveactivity');
  rmSync(dir, { recursive: true, force: true });
});


test('payload sanitizes control characters before measuring the Apple limit', () => {
  const state = contentFor({ item: { type: 'track', name: '\u0000'.repeat(1000), artists: [{ name: '\u0001'.repeat(1000) }] } },
    { lines: [{ time: 0, text: '\u0000'.repeat(1000) }, { time: 10, text: '\u0000'.repeat(1000) }] }, 0);
  assert.ok(Buffer.byteLength(makePayload(state, 'update', 1000)) <= 4096);
});

test('new HTTP session requires valid Spotify proof and uses its own capability', async t => {
  const f = fixture(); t.after(() => f.store.close());
  const app = server({ ...f, clientID: 'test-client', now: f.now });
  await new Promise(resolve => app.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => app.close(resolve)));
  const id = randomUUID(); const secret = randomBytes(32).toString('base64url');
  const url = `http://127.0.0.1:${app.address().port}/v1/sessions/${id}`;
  const put = tokens => fetch(url, { method: 'PUT', headers: { authorization: `Bearer ${secret}` }, body: JSON.stringify({ tokens }) });
  assert.equal((await put({ ...f.tokens, clientID: 'another-app' })).status, 400);
  assert.equal((await put(f.tokens)).status, 200);
  assert.equal(f.store.authorized(id, secret), true);
  assert.equal(f.store.authorized(id, f.secret), false);
  assert.equal(f.store.get(id).expires, f.now() + 21600000);
});

test('stopping waits for an in-flight token rotation and returns the latest token', async t => {
  const f = fixture(); t.after(() => f.store.close());
  const s = f.store.get(f.id); s.tokens.expiresAt = new Date(f.now()).toISOString(); f.store.save(f.id, s);
  let release;
  f.spotify.refresh = async tokens => {
    await new Promise(resolve => { release = resolve; });
    return { ...tokens, refreshToken: 'rotated-during-stop', expiresAt: new Date(f.now() + 3600000).toISOString() };
  };
  const tick = f.worker.runOnce();
  await new Promise(resolve => setImmediate(resolve));
  const stop = f.worker.stop(f.id);
  release();
  await tick;
  assert.equal((await stop).refreshToken, 'rotated-during-stop');
  assert.equal(f.store.get(f.id), null);
});
