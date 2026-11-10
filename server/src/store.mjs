import { DatabaseSync } from 'node:sqlite';
import { createCipheriv, createDecipheriv, createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';

export class Store {
  constructor(path, key) {
    this.key = Buffer.from(key, 'base64');
    if (this.key.length !== 32) throw new Error('DATA_KEY must contain 32 random bytes in base64');
    if (path !== ':memory:') mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(path);
    if (path !== ':memory:') chmodSync(path, 0o600);
    this.db.exec('PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, auth TEXT NOT NULL, value TEXT NOT NULL)');
  }
  hash(secret) { return createHash('sha256').update(secret).digest('hex'); }
  encode(id, value) {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, iv);
    cipher.setAAD(Buffer.from(id));
    const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
    return Buffer.concat([iv, cipher.getAuthTag(), data]).toString('base64');
  }
  decode(id, value) {
    const data = Buffer.from(value, 'base64');
    const cipher = createDecipheriv('aes-256-gcm', this.key, data.subarray(0, 12));
    cipher.setAAD(Buffer.from(id)); cipher.setAuthTag(data.subarray(12, 28));
    return JSON.parse(Buffer.concat([cipher.update(data.subarray(28)), cipher.final()]).toString());
  }
  get(id) {
    const row = this.db.prepare('SELECT value FROM sessions WHERE id=?').get(id);
    return row ? this.decode(id, row.value) : null;
  }
  authorized(id, secret) {
    const row = this.db.prepare('SELECT auth FROM sessions WHERE id=?').get(id);
    return !!row && timingSafeEqual(Buffer.from(row.auth, 'hex'), Buffer.from(this.hash(secret), 'hex'));
  }
  create(id, secret, value) {
    this.db.prepare('INSERT INTO sessions VALUES (?,?,?)').run(id, this.hash(secret), this.encode(id, value));
  }
  save(id, value) { this.db.prepare('UPDATE sessions SET value=? WHERE id=?').run(this.encode(id, value), id); }
  remove(id) { this.db.prepare('DELETE FROM sessions WHERE id=?').run(id); }
  ids() { return this.db.prepare('SELECT id FROM sessions').all().map(x => x.id); }
  close() { this.db.close(); }
}
