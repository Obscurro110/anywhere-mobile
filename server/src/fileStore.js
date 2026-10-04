import { createReadStream, mkdirSync, createWriteStream, unlinkSync, existsSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';

/**
 * Simple file store used by the relay to hand files between devices.
 * Files are content-addressed by a random id and auto-purged after ttlMs.
 */
/**
 * 清洗文件名：去掉换行/控制字符，防止 CRLF 注入到 Content-Disposition 头。
 * 顺便限长并给空名兜底。
 */
function sanitizeName(name, fallback = 'file.bin') {
  const cleaned = String(name ?? '')
    .replace(/[\r\n\0\t]/g, '')
    .replace(/["\\]/g, '_')
    .trim();
  if (!cleaned) return fallback;
  return cleaned.slice(0, 180);
}

export function createFileStore({ dir, maxBytes, ttlMs }) {
  const baseDir = resolve(dir);
  mkdirSync(baseDir, { recursive: true });

  const index = new Map(); // id -> { id, name, size, mime, createdAt, path }

  /**
   * 启动时从磁盘重建索引。
   *
   * 以前 index 只存在内存里：进程一重启，磁盘上已上传的文件就"查不到"了
   * —— 客户端 404、又因为 purge() 只遍历内存 index 而永远不被清理，
   * 磁盘越堆越大。现在启动时扫描 *.meta.json 重建索引，
   * 并把没有 meta 的孤儿 *.bin 直接清掉。
   */
  (function rebuildIndex() {
    let entries = [];
    try {
      entries = readdirSync(baseDir);
    } catch { return; }

    const metaIds = new Set();
    for (const f of entries) {
      if (!f.endsWith('.meta.json')) continue;
      const id = f.slice(0, -'.meta.json'.length);
      try {
        const meta = JSON.parse(readFileSync(join(baseDir, f), 'utf8'));
        const p = dataPath(id);
        if (meta && meta.id && existsSync(p)) {
          const st = statSync(p);
          index.set(id, { id, name: meta.name || 'file.bin', size: st.size, mime: meta.mime, createdAt: meta.createdAt || st.mtimeMs, path: p });
          metaIds.add(id);
        }
      } catch {}
    }
    // 孤儿 .bin（没有对应 meta 的）直接删掉
    for (const f of entries) {
      if (!f.endsWith('.bin')) continue;
      const id = f.slice(0, -'.bin'.length);
      if (!metaIds.has(id)) {
        try { unlinkSync(join(baseDir, f)); } catch {}
      }
    }
  })();

  function metaPath(id) {
    return join(baseDir, `${id}.meta.json`);
  }
  function dataPath(id) {
    return join(baseDir, `${id}.bin`);
  }

  function persistMeta(meta) {
    try {
      writeFileSync(metaPath(meta.id), JSON.stringify({ id: meta.id, name: meta.name, mime: meta.mime, createdAt: meta.createdAt }), 'utf8');
    } catch {}
  }

  // Save from a raw http request stream
  async function saveStream(stream, name, mime = 'application/octet-stream') {
    const id = randomUUID();
    const safeName = sanitizeName(name);
    const out = createWriteStream(dataPath(id));
    let size = 0;
    stream.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) stream.destroy(new Error('file_too_large'));
    });
    await pipeline(stream, out);
    const meta = { id, name: safeName, size, mime, createdAt: Date.now(), path: dataPath(id) };
    index.set(id, meta);
    persistMeta(meta);
    return publicMeta(meta);
  }

  // Save from an in-memory base64 payload (used for small ws chunked transfers)
  async function saveBase64(base64, name, mime = 'application/octet-stream') {
    let buf;
    try {
      buf = Buffer.from(base64, 'base64');
    } catch {
      throw new Error('bad_base64');
    }
    if (buf.length > maxBytes) throw new Error('file_too_large');
    const id = randomUUID();
    await pipeline(Readable.from(buf), createWriteStream(dataPath(id)));
    const meta = { id, name: sanitizeName(name), size: buf.length, mime, createdAt: Date.now(), path: dataPath(id) };
    index.set(id, meta);
    persistMeta(meta);
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
      'content-disposition': `attachment; filename="${encodeURIComponent(sanitizeName(meta.name))}"`,
      'x-content-type-options': 'nosniff',
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
    try { if (existsSync(metaPath(id))) unlinkSync(metaPath(id)); } catch {}
    index.delete(id);
  }

  function publicMeta(m) {
    return { id: m.id, name: m.name, size: m.size, mime: m.mime, createdAt: m.createdAt };
  }

  return { saveStream, saveBase64, get, serve, purge, remove, publicMeta };
}
