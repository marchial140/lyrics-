import http2 from 'node:http2';
import { createPrivateKey, sign } from 'node:crypto';
import { readFileSync } from 'node:fs';

export class RemoteError extends Error {
  constructor(status, retry = 30) { super(`Upstream HTTP ${status}`); this.status = status; this.retry = retry; }
}
export async function jsonFetch(url, options = {}) {
  const response = await fetch(url, { ...options, signal: AbortSignal.timeout(10000) });
  if (response.status === 204) return null;
  if (!response.ok) throw new RemoteError(response.status, Math.max(1, Number(response.headers.get('retry-after')) || 30));
  const data = await response.text();
  if (Buffer.byteLength(data) > 1048576) throw new Error('Upstream response too large');
  return JSON.parse(data);
}
export const spotify = {
  playback(accessToken) {
    return jsonFetch('https://api.spotify.com/v1/me/player/currently-playing', { headers: { Authorization: `Bearer ${accessToken}` } });
  },
  async refresh(tokens) {
    const result = await jsonFetch('https://accounts.spotify.com/api/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: tokens.refreshToken, client_id: tokens.clientID })
    });
    if (!result.access_token || !result.expires_in) throw new Error('Invalid token response');
    return { ...tokens, accessToken: result.access_token, refreshToken: result.refresh_token || tokens.refreshToken,
      expiresAt: new Date(Date.now() + result.expires_in * 1000).toISOString() };
  }
};
export function parseLRC(source = '') {
  const offset = Number(source.match(/\[offset:([+-]?\d+)\]/i)?.[1] || 0) / 1000;
  const times = new Map();
  for (const row of source.split(/\r?\n/)) {
    const tags = [...row.matchAll(/\[(\d{1,3}):(\d{2}(?:\.\d{1,3})?)\]/g)];
    if (!tags.length) continue;
    const last = tags.at(-1);
    const text = row.slice(last.index + last[0].length).trim();
    for (const tag of tags) if (Number(tag[2]) < 60) times.set(Math.max(0, Number(tag[1]) * 60 + Number(tag[2]) - offset), text);
  }
  return [...times].sort((a, b) => a[0] - b[0]).map(([time, text]) => ({ time, text }));
}
export class Lyrics {
  constructor() { this.cache = new Map(); this.next = 0; }
  async load(item) {
    const key = item.id || `${item.name}|${item.artists?.[0]?.name}|${item.duration_ms}`;
    const cached = this.cache.get(key);
    if (cached && cached.until > Date.now()) return cached.value;
    if (Date.now() < this.next) throw new RemoteError(429, (this.next - Date.now()) / 1000);
    this.next = Date.now() + 400;
    const params = new URLSearchParams({ track_name: item.name, artist_name: item.artists?.[0]?.name || '' });
    if (item.album?.name) params.set('album_name', item.album.name);
    const seconds = item.duration_ms / 1000;
    if (seconds >= 1 && seconds <= 3600) params.set('duration', String(seconds));
    let result;
    try {
      result = await jsonFetch(`https://lrclib.net/api/get?${params}`, { headers: { 'User-Agent': 'LyricLive/0.4 (https://github.com/marchial140/lyrics-)' } });
    } catch (error) {
      if (error.status === 404) result = {};
      else {
        if ([429, 503].includes(error.status)) this.next = Date.now() + error.retry * 1000 * (1 + Math.random() * 0.3);
        throw error;
      }
    }
    const value = { lines: parseLRC(result.syncedLyrics), message: result.instrumental ? 'Morceau instrumental' : result.plainLyrics ? 'Paroles non synchronisées' : 'Paroles indisponibles' };
    if (this.cache.size >= 50) this.cache.delete(this.cache.keys().next().value);
    this.cache.set(key, { until: Date.now() + 600000, value });
    return value;
  }
}
const clip = (value, count) => Array.from(String(value).replace(/[\u0000-\u001f\u007f]/g, " ")).slice(0, count).join("");
export function contentFor(playback, document, position) {
  const item = playback?.item;
  if (!item || item.type !== 'track') return { line: 'Aucun morceau disponible', nextLine: '', lineNumber: 0,
    isPlaying: false, status: 'Ouvre Spotify', trackTitle: 'LyricLive', trackArtist: '' };
  let index = -1;
  const lines = document?.lines || [];
  for (let i = 0; i < lines.length && lines[i].time <= position; i++) index = i;
  return {
    line: clip(index >= 0 ? lines[index].text || '♪' : lines.length ? '♪' : document?.message || 'Recherche des paroles…', 200),
    nextLine: clip(lines[index + 1]?.text || '', 200),
    lineNumber: index + 1, isPlaying: !!playback.is_playing,
    status: playback.is_playing ? 'En lecture · LRCLIB' : 'Spotify en pause · LRCLIB',
    trackTitle: clip(item.name, 100),
    trackArtist: clip(item.artists?.map(x => x.name).join(', ') || '', 100)
  };
}
export function makePayload(state, event, timestamp) {
  const aps = { timestamp, event, 'content-state': state, 'stale-date': timestamp + 30 };
  if (event === 'end') aps['dismissal-date'] = timestamp;
  const body = JSON.stringify({ aps });
  if (Buffer.byteLength(body) > 4096) throw new Error('APNs payload exceeds 4KB');
  return body;
}
export class Apns {
  constructor({ teamID, keyID, bundleID, keyPath, environment }) {
    if (!/^[A-Z0-9]{10}$/.test(teamID || '') || !/^[A-Z0-9]{10}$/.test(keyID || '')) throw new Error('Invalid Apple Team ID / Key ID');
    if (!/^[a-zA-Z0-9.-]+$/.test(bundleID || '') || !['development', 'production'].includes(environment)) throw new Error('Invalid APNs bundle/environment');
    this.teamID = teamID; this.keyID = keyID; this.topic = bundleID + '.push-type.liveactivity';
    this.key = createPrivateKey(readFileSync(keyPath));
    if (this.key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNs requires an ES256 key');
    this.host = environment === 'production' ? 'https://api.push.apple.com' : 'https://api.sandbox.push.apple.com';
  }
  jwt() {
    if (this.cached && Date.now() - this.cachedAt < 3000000) return this.cached;
    const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: this.keyID })).toString('base64url');
    const claims = Buffer.from(JSON.stringify({ iss: this.teamID, iat: Math.floor(Date.now() / 1000) })).toString('base64url');
    const text = `${header}.${claims}`;
    this.cached = `${text}.${sign('sha256', Buffer.from(text), { key: this.key, dsaEncoding: 'ieee-p1363' }).toString('base64url')}`;
    this.cachedAt = Date.now(); return this.cached;
  }
  async send(session, state, event, timestamp) {
    const body = makePayload(state, event, timestamp);
    await new Promise((resolve, reject) => {
      const connection = http2.connect(this.host);
      const timer = setTimeout(() => { connection.destroy(); reject(new Error('APNs timeout')); }, 8000);
      const finish = (error) => { clearTimeout(timer); connection.close(); error ? reject(error) : resolve(); };
      connection.once('error', finish);
      const request = connection.request({ ':method': 'POST', ':path': `/3/device/${session.pushToken}`,
        authorization: `bearer ${this.jwt()}`, 'apns-topic': this.topic,
        'apns-push-type': 'liveactivity', 'apns-priority': '5', 'apns-expiration': String(Math.floor(Date.now() / 1000) + 60) });
      let status = 0;
      request.on('response', headers => { status = headers[':status']; });
      request.on('data', () => {});
      request.once('error', finish);
      request.once('end', () => finish(status === 200 ? null : Object.assign(new RemoteError(status), { origin: 'apns' })));
      request.end(body);
    }).catch(error => { error.origin = "apns"; throw error; });
  }
}
