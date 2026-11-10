import { Store } from './store.mjs';
import { Apns, Lyrics, spotify } from './services.mjs';
import { Worker } from './worker.mjs';
import { server } from './http.mjs';

const store = new Store(process.env.DATA_PATH || './data/sessions.sqlite', process.env.DATA_KEY || '');
const apns = new Apns({ teamID: process.env.APPLE_TEAM_ID, keyID: process.env.APNS_KEY_ID,
  bundleID: process.env.APP_BUNDLE_ID, keyPath: process.env.APNS_KEY_PATH, environment: process.env.APNS_ENVIRONMENT });
const worker = new Worker({ store, spotify, lyrics: new Lyrics(), apns });
const app = server({ store, worker, spotify, clientID: process.env.SPOTIFY_CLIENT_ID || '7f18a254cf5141ba8f2cef13397c80ba' });
let running = false;
const timer = setInterval(async () => {
  if (running) return;
  running = true;
  try { await worker.runOnce(); } catch { console.error('Worker iteration failed'); }
  finally { running = false; }
}, 1000);
app.listen(Number(process.env.PORT || 8080), process.env.HOST || '127.0.0.1', () => console.log('LyricLive backend started'));
async function shutdown() {
  clearInterval(timer);
  app.close();
  // Leave encrypted sessions on disk for a restart; APNs stale-date shows outages.
  const finish = setInterval(() => { if (!running) { clearInterval(finish); store.close(); process.exit(0); } }, 100);
  setTimeout(() => process.exit(1), 15000).unref();
}
process.on('SIGTERM', shutdown); process.on('SIGINT', shutdown);
