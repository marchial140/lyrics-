import { createServer } from 'node:http';

const fail = (code, text) => Object.assign(new Error(text), { code });
async function readBody(request) {
  let data = '';
  for await (const chunk of request) {
    data += chunk;
    if (Buffer.byteLength(data) > 16384) throw fail(413, 'Request too large');
  }
  try { return JSON.parse(data); } catch { throw fail(400, 'Invalid JSON'); }
}
export function server({ store, worker, spotify, clientID, maxSessions = 10, now = Date.now }) {
  const requests = new Map();
  let creating = 0;
  return createServer({ requestTimeout: 15000, headersTimeout: 10000 }, async (request, response) => {
    const reply = (status, body) => {
      response.writeHead(status, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
      response.end(JSON.stringify(body));
    };
    try {
      if (request.url === '/healthz' && request.method === 'GET') return reply(200, { ok: true });
      const ip = request.socket.remoteAddress;
      if (requests.size > 10000) requests.clear();
      const bucket = requests.get(ip) || { start: now(), count: 0 };
      if (now() - bucket.start > 60000) { bucket.start = now(); bucket.count = 0; }
      requests.set(ip, bucket);
      if (++bucket.count > 180) throw fail(429, 'Too many requests');
      const match = /^\/v1\/sessions\/([a-f0-9-]{36})(?:\/(activity|playback))?$/.exec(request.url || '');
      const bearer = /^Bearer ([A-Za-z0-9_-]{43,128})$/.exec(request.headers.authorization || '');
      if (!match || !bearer) throw fail(401, 'Unauthorized');
      const [, id, action] = match;
      const secret = bearer[1];
      if (request.method === 'DELETE' && !action) {
        if (!store.authorized(id, secret)) throw fail(401, 'Unauthorized');
        const tokens = await worker.stop(id);
        return reply(200, { tokens });
      }
      const result = await worker.lock(id, async () => {
        const existing = store.get(id);
        if (request.method === 'PUT' && !action) {
          const body = await readBody(request);
          if (existing) {
            if (!store.authorized(id, secret)) throw fail(401, 'Unauthorized');
            // Never overwrite a refreshed server-owned token with an older phone copy.
            return { ok: true, expiresAt: new Date(existing.expires).toISOString() };
          }
          if (store.ids().length + creating >= maxSessions) throw fail(503, 'Session limit reached');
          const t = body.tokens;
          if (!t || t.clientID !== clientID || ![t.accessToken, t.refreshToken].every(x => typeof x === 'string' && x.length >= 10 && x.length <= 4096)
              || !Number.isFinite(Date.parse(t.expiresAt))) throw fail(400, 'Invalid Spotify credentials');
          creating++;
          try { await spotify.playback(t.accessToken); }
          catch { throw fail(401, 'Spotify authorization failed'); }
          finally { creating--; }
          const value = { tokens: t, expires: now() + 6 * 3600000, nextPoll: 0, pushToken: null, activityVersion: 0, frequent: false };
          store.create(id, secret, value);
          return { ok: true, expiresAt: new Date(value.expires).toISOString() };
        }
        if (!existing || !store.authorized(id, secret)) throw fail(401, 'Unauthorized');
        if (request.method === 'GET' && action === 'playback') return { playback: worker.playback(id), deliveryStatus: existing.deliveryStatus || null };
        if (request.method === 'DELETE' && action === 'activity') {
          const body = await readBody(request);
          if (!Number.isSafeInteger(body.version) || body.version < existing.activityVersion) throw fail(409, 'Stale activity');
          existing.pushToken = null; existing.activityID = null; existing.activityVersion = body.version;
          store.save(id, existing);
          return { ok: true };
        }
        if (request.method === 'PUT' && action === 'activity') {
          const body = await readBody(request);
          if (!/^[a-f0-9]{32,1024}$/i.test(body.pushToken || '') || !Number.isSafeInteger(body.version) || body.version < 1
              || typeof body.activityID !== 'string' || body.activityID.length > 128) throw fail(400, 'Invalid activity registration');
          if (body.version < existing.activityVersion) throw fail(409, 'Stale activity');
          if (body.version === existing.activityVersion && existing.activityID !== body.activityID) throw fail(409, 'Conflicting activity');
          existing.pushToken = body.pushToken; existing.activityID = body.activityID;
          existing.activityVersion = body.version; existing.frequent = body.frequent === true;
          store.save(id, existing);
          return { ok: true };
        }
        throw fail(404, 'Unknown route');
      });
      reply(200, result);
    } catch (error) {
      // Never return/log upstream bodies, token values, database content or exception stacks.
      reply(error.code >= 400 && error.code <= 599 ? error.code : 502, { error: error.code ? error.message : 'Service unavailable' });
    }
  });
}
