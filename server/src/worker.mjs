import { contentFor } from './services.mjs';

export class Worker {
  constructor({ store, spotify, lyrics, apns, now = Date.now }) {
    Object.assign(this, { store, spotify, lyrics, apns, now });
    this.runtime = new Map(); this.locks = new Map();
  }
  async lock(id, action) {
    const previous = this.locks.get(id) || Promise.resolve();
    const next = previous.catch(() => {}).then(action);
    this.locks.set(id, next);
    try { return await next; } finally { if (this.locks.get(id) === next) this.locks.delete(id); }
  }
  async stop(id) {
    return this.lock(id, async () => {
      const s = this.store.get(id);
      if (!s) return null;
      try { if (s.pushToken) await this.apns.send(s, contentFor(null), 'end', this.timestamp(s)); } catch {}
      this.store.remove(id); this.runtime.delete(id);
      return s.tokens;
    });
  }
  timestamp(s) { s.lastTimestamp = Math.max(Math.floor(this.now() / 1000), (s.lastTimestamp || 0) + 1); return s.lastTimestamp; }
  async runOnce() {
    // Single-process deployment; all paths touching one session use this same lock.
    await Promise.all(this.store.ids().map(id => this.lock(id, () => this.tick(id))));
  }
  async tick(id) {
    const s = this.store.get(id);
    if (!s) return;
    if (s.expires <= this.now()) {
      try { if (s.pushToken) await this.apns.send(s, contentFor(null), 'end', this.timestamp(s)); } catch {}
      this.store.remove(id); this.runtime.delete(id); return;
    }
    const r = this.runtime.get(id) || { position: 0, sampled: 0, playback: null, lastPush: 0, signature: '', lyricsNext: 0, nextPush: 0 };
    this.runtime.set(id, r);
    try {
      if (this.now() >= (s.nextPoll || 0)) {
        if (Date.parse(s.tokens.expiresAt) < this.now() + 60000) {
          s.tokens = await this.spotify.refresh(s.tokens); this.store.save(id, s);
        }
        try { r.playback = await this.spotify.playback(s.tokens.accessToken); }
        catch (error) {
          if (error.status !== 401) throw error;
          s.tokens = await this.spotify.refresh(s.tokens); this.store.save(id, s);
          r.playback = await this.spotify.playback(s.tokens.accessToken);
        }
        r.position = (r.playback?.progress_ms || 0) / 1000; r.sampled = this.now();
        s.nextPoll = this.now() + 3000;
      }
      const item = r.playback?.item;
      const key = item?.type === 'track' ? item.id || item.uri || item.name : null;
      if (r.key !== key) { r.key = key; r.document = null; r.lyricsNext = 0; }
      if (key && !r.document && this.now() >= r.lyricsNext) {
        try { r.document = await this.lyrics.load(item); }
        catch (error) {
          r.lyricsNext = this.now() + ([429, 503].includes(error.status) ? error.retry * 1000 : 30000);
        }
      }
      const position = r.position + (r.playback?.is_playing ? Math.max(0, this.now() - r.sampled) / 1000 : 0);
      const state = contentFor(r.playback, r.document, Math.min(position, item?.duration_ms ? item.duration_ms / 1000 : position));
      const signature = JSON.stringify(state);
      const minimum = s.frequent ? 2000 : 15000;
      // Resend after token rotation, and refresh the stale-date at most every 20 seconds.
      if (s.pushToken && this.now() >= (s.nextPush || 0) && (signature !== r.signature || s.pushToken !== r.pushToken || this.now() - r.lastPush >= 20000) && this.now() - r.lastPush >= minimum) {
        await this.apns.send(s, state, 'update', this.timestamp(s));
        s.deliveryStatus = null;
        r.signature = signature; r.lastPush = this.now(); r.pushToken = s.pushToken;
      }
    } catch (error) {
      if (error.origin === 'apns') {
        s.deliveryStatus = `Apple push HTTP ${error.status || 0}`;
        s.nextPush = this.now() + Math.max(10, error.retry || 30) * 1000;
        if ([400, 404, 410].includes(error.status)) s.pushToken = null;
        this.store.save(id, s);
        return;
      }
      if ([400, 401, 403].includes(error.status)) {
        try { if (s.pushToken) await this.apns.send(s, { ...contentFor(null), line: 'Reconnecte Spotify dans LyricLive' }, 'end', this.timestamp(s)); } catch {}
        this.store.remove(id); this.runtime.delete(id); return;
      }
      if ([410, 404].includes(error.status)) {
        s.pushToken = null; r.signature = '';
      }
      s.nextPoll = this.now() + ([429, 503].includes(error.status) ? Math.max(1, error.retry) * 1000 : 10000);
      // Do not continue extrapolating or showing a song after a playback/network failure.
      r.playback = null; r.document = null; r.key = null;
    }
    if (this.store.get(id)) this.store.save(id, s);
  }
  playback(id) { return this.runtime.get(id)?.playback ?? null; }
}
