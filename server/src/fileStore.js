import { createReadStream, mkdirSync, createWriteStream, unlinkSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';

/**
 * Simple file store used by the relay to hand files between devices.
 * Files are content-addressed by a random id and auto-purged after ttlMs.
 */
export function createFileStore({ dir, maxBytes, ttlMs }) {
  const baseDir = resolve(dir);
  mkdirSync(baseDir, { recursive: true });

  const index = new Map(); // id -> { id, name, size, mime, createdAt, path }

  function metaPath(id) {
    return join(baseDir, `${id}.meta.json`);
  }
  function dataPath(id) {
    return join(baseDir, `${id}.bin`);
  }

  // Save from a raw http request stream
  async function saveStream(stream, name, mime = 'application/octet-stream') {
    const id = randomUUID();
    const out = createWriteStream(dataPath(id));
    let size = 0;
    stream.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) stream.destroy(new Error('file_too_large'));
    });
    await pipeline(stream, out);
    const meta = { id, name, size, mime, createdAt: Date.now(), path: dataPath(id) };
    index.set(id, meta);
    return publicMeta(meta);
  }

  // Save from an in-memory base64 payload (used for small ws chunked transfers)
  async function saveBase64(base64, name, mime = 'application/octet-stream') {
    const buf = Buffer.from(base64, 'base64');
    if (buf.length > maxBytes) throw new Error('file_too_large');
    const id = randomUUID();
    await pipeline(Readable.from(buf), createWriteStream(dataPath(id)));
    const meta = { id, name, size: buf.length, mime, createdAt: Date.now(), path: dataPath(id) };
    index.set(id, meta);
    return publicMeta(meta);
  }

  function get(id) {
    return index.get(id) || null;
  }

  async function serve(id, req, res) {
    const meta = index.get(id);
    if (!meta || !existsSync(meta.path)) {
      res.writeHead(404, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ ok: false, error: 'not_found' }));
      return;
    }
    res.writeHead(200, {
      'content-type': meta.mime || 'application/octet-stream',
      'content-length': meta.size,
      'content-disposition': `attachment; filename="${encodeURIComponent(meta.name)}"`,
    });
    await pipeline(createReadStream(meta.path), res);
  }

  function purge() {
    const now = Date.now();
    for (const [id, meta] of index.entries()) {
      if (now - meta.createdAt > ttlMs) remove(id);
    }
  }

  function remove(id) {
    const meta = index.get(id);
    if (!meta) return;
    try { if (existsSync(meta.path)) unlinkSync(meta.path); } catch {}
    index.delete(id);
  }

  function publicMeta(m) {
    return { id: m.id, name: m.name, size: m.size, mime: m.mime, createdAt: m.createdAt };
  }

  return { saveStream, saveBase64, get, serve, purge, remove, publicMeta };
}
