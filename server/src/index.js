import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createFileStore } from './fileStore.js';
import { createWss } from './wsHub.js';
import { parseTokens, validateTokenConfig, userForToken } from './auth.js';

// ---- tiny .env loader (no dependency) ----
const __dirname = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.resolve(__dirname, '..', '.env');
if (existsSync(envPath)) {
  for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}

const PORT = parseInt(process.env.PORT || '8787', 10);
const HOST = process.env.HOST || '0.0.0.0';
const FILE_DIR = process.env.FILE_DIR || './data/files';
const MAX_FILE_MB = parseInt(process.env.MAX_FILE_MB || '512', 10);
const FILE_TTL_HOURS = parseInt(process.env.FILE_TTL_HOURS || '72', 10);

const tokens = parseTokens(process.env.AUTH_TOKENS || 'default-user:CHANGE_ME_TOKEN');
const tokenCheck = validateTokenConfig(tokens);
if (tokenCheck.warn.length > 0) {
  console.warn('[relay] ⚠️ AUTH_TOKENS 安全性提醒：');
  for (const w of tokenCheck.warn) console.warn('[relay]   - ' + w);
}
if (tokenCheck.fatal.length > 0) {
  console.error('[relay] AUTH_TOKENS 配置不安全，拒绝启动：');
  for (const p of tokenCheck.fatal) console.error('[relay]   - ' + p);
  console.error('[relay] 请在 .env / 环境变量里设置 token（不要用默认占位值）。');
  process.exit(1);
}

const fileStore = createFileStore({
  dir: FILE_DIR,
  maxBytes: MAX_FILE_MB * 1024 * 1024,
  ttlMs: FILE_TTL_HOURS * 3600 * 1000,
});

const server = http.createServer(async (req, res) => {
  try {
    await handleHttp(req, res);
  } catch (err) {
    // 不把 err 细节返回给客户端，避免泄露内部路径/栈
    console.error('[relay] http error', err);
    const body = JSON.stringify({ ok: false, error: 'internal_error' });
    if (!res.headersSent) {
      res.writeHead(500, {
        ...SECURITY_HEADERS,
        'content-length': Buffer.byteLength(body),
      });
      res.end(body);
    } else {
      res.end();
    }
  }
});

async function handleHttp(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // health check
  if (url.pathname === '/health') {
    return json(res, 200, { ok: true, service: 'anywhere-relay', version: 1 });
  }

  // download a relayed file: /file/:id?token=...
  const fileMatch = url.pathname.match(/^\/file\/([\w-]+)$/);
  if (fileMatch) {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      return json(res, 405, { ok: false, error: 'method_not_allowed' });
    }
    const token = url.searchParams.get('token');
    if (!token || !isValidToken(token)) {
      return json(res, 401, { ok: false, error: 'unauthorized' });
    }
    return fileStore.serve(fileMatch[1], req, res);
  }

  // upload a file (used for large files instead of ws chunks):
  // POST /upload?token=...&name=...  (raw body)
  if (url.pathname === '/upload' && req.method === 'POST') {
    const token = url.searchParams.get('token');
    if (!token || !isValidToken(token)) {
      return json(res, 401, { ok: false, error: 'unauthorized' });
    }
    const name = url.searchParams.get('name') || 'file.bin';
    try {
      const meta = await fileStore.saveStream(req, name);
      return json(res, 200, { ok: true, file: meta });
    } catch (err) {
      // 不要把内部错误信息原样抛给客户端（可能暴露路径/实现细节）
      const msg = String(err?.message || err || '');
      const userMsg = msg.includes('too_large') ? 'file_too_large' : 'upload_failed';
      console.error('[relay] upload failed:', msg);
      return json(res, 413, { ok: false, error: userMsg });
    }
  }

  return json(res, 404, { ok: false, error: 'not_found' });
}

// ⚠️ 时序安全：不要用 `v === t` 提前短路比较，否则能用响应耗时逐字节爆破 token。
function isValidToken(t) {
  return userForToken(tokens, t) !== null;
}

// 统一安全响应头（对公网服务尤其重要）
const SECURITY_HEADERS = {
  'content-type': 'application/json',
  'x-content-type-options': 'nosniff',
  'x-frame-options': 'DENY',
  'cache-control': 'no-store',
};

function json(res, code, obj, extraHeaders = {}) {
  const body = JSON.stringify(obj);
  res.writeHead(code, {
    ...SECURITY_HEADERS,
    'content-length': Buffer.byteLength(body),
    ...extraHeaders,
  });
  res.end(body);
}

// ---- WebSocket hub ----
const { wss } = createWss({ server, tokens, fileStore });

server.listen(PORT, HOST, () => {
  console.log(`[relay] listening on http://${HOST}:${PORT}`);
  console.log(`[relay] ws endpoint     ws://${HOST}:${PORT}/ws`);
  console.log(`[relay] users          ${[...tokens.keys()].join(', ')}`);
  console.log(`[relay] files stored   ${path.resolve(FILE_DIR)}`);
});

// periodic purge
setInterval(() => fileStore.purge(), 30 * 60 * 1000);

// 优雅关闭：Docker/1Panel 停止容器时发的是 SIGTERM，不能只处理 SIGINT，
// 否则文件流写一半就被强杀。
function shutdown(signal) {
  console.log(`\n[relay] ${signal} received, shutting down...`);
  // 给在途请求一点时间收尾
  const force = setTimeout(() => process.exit(1), 10_000);
  force.unref?.();
  try {
    wss.close(() => {
      server.close(() => process.exit(0));
    });
  } catch {
    process.exit(0);
  }
}
process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));
