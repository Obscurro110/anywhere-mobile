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
 * 清洗文件名：去掉换行/控制字符（防 CRLF 注入到 Content-Disposition 头），
 * 去掉路径分隔符与 `..` 片段（防下载方按这个名字落盘时被穿越），
 * 顺便限长并给空名兜底。
 */
function sanitizeName(name, fallback = 'file.bin') {
  const cleaned = String(name ?? '')
    .replace(/[\r\n\0\t]/g, '')      // 控制字符
    .replace(/["\\/]/g, '_')          // 引号 + 路径分隔符（含 Windows 的 \ ）
    .replace(/\.{2,}/g, '_')          // .. 片段（保留普通扩展名的单个点）
    .trim();
  if (!cleaned) return fallback;
  return cleaned.slice(0, 180);
}

export function createFileStore({ dir, maxBytes, ttlMs }) {
  const baseDir = resolve(dir);
  mkdirSync(baseDir, { recursive: true });

  const index = new Map(); // id -> { id, name, size, mime, createdAt, path, owner }

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
          index.set(id, { id, name: meta.name || 'file.bin', size: st.size, mime: meta.mime, createdAt: meta.createdAt || st.mtimeMs, path: p, owner: meta.owner || null });
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
      writeFileSync(metaPath(meta.id), JSON.stringify({ id: meta.id, name: meta.name, mime: meta.mime, createdAt: meta.createdAt, owner: meta.owner || null }), 'utf8');
    } catch {}
  }

  // Save from a raw http request stream
  async function saveStream(stream, name, mime = 'application/octet-stream', owner = null) {
    const id = randomUUID();
    const safeName = sanitizeName(name);
    const outPath = dataPath(id);
    const out = createWriteStream(outPath);
    let size = 0;
    stream.on('data', (c) => {
      size += c.length;
      if (size > maxBytes) stream.destroy(new Error('file_too_large'));
    });
    try {
      await pipeline(stream, out);
    } catch (err) {
      // 失败（超限/断流）时清掉已写的半截文件，避免磁盘残留
      try { if (existsSync(outPath)) unlinkSync(outPath); } catch {}
      throw err;
    }
    const meta = { id, name: safeName, size, mime, createdAt: Date.now(), path: outPath, owner };
    index.set(id, meta);
    persistMeta(meta);
    return publicMeta(meta);
  }

  // Save from an in-memory base64 payload (used for small ws chunked transfers)
  async function saveBase64(base64, name, mime = 'application/octet-stream', owner = null) {
    let buf;
    try {
      buf = Buffer.from(base64, 'base64');
    } catch {
      throw new Error('bad_base64');
    }
    if (buf.length > maxBytes) throw new Error('file_too_large');
    const id = randomUUID();
    const outPath = dataPath(id);
    try {
      await pipeline(Readable.from(buf), createWriteStream(outPath));
    } catch (err) {
      try { if (existsSync(outPath)) unlinkSync(outPath); } catch {}
      throw err;
    }
    const meta = { id, name: sanitizeName(name), size: buf.length, mime, createdAt: Date.now(), path: outPath, owner };
    index.set(id, meta);
    persistMeta(meta);
    return publicMeta(meta);
  }

  function get(id) {
    return index.get(id) || null;
  }

  /**
   * ⚠️ 归属校验：/file/:id 以前只校验「token 有效」，不校验这个文件是不是
   * 你的 —— 任何账号只要拿到别人的 fileId（file_share 消息里就有），就能
   * 下载别人的文件。现在要求 owner 匹配。
   *
   * 没有 owner 的历史文件只在服务端只配置了一个账号时放行。多账号时拒绝，
   * 避免旧文件被其他有效账号凭 fileId 下载。
   */
  function owns(meta, requesterUser, singleUserMode) {
    if (!meta || !requesterUser) return false;
    if (!meta.owner) return singleUserMode;
    return meta.owner === requesterUser;
  }

  async function serve(id, req, res, requesterUser = null, singleUserMode = false) {
    const meta = index.get(id);
    // 归属不符时返回 404（而不是 403）：不向调用方确认"这个 id 存在"
    if (!meta || !existsSync(meta.path) || !owns(meta, requesterUser, singleUserMode)) {
      res.writeHead(404, { 'content-type': 'application/json', 'x-content-type-options': 'nosniff', 'cache-control': 'no-store' });
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
