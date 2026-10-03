import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { createFileStore } from './fileStore.js';
import { createWss } from './wsHub.js';
import { parseTokens } from './auth.js';

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
if (tokens.size === 0) {
  console.error('[relay] No AUTH_TOKENS configured. Refusing to start.');
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
    console.error('[relay] http error', err);
    res.writeHead(500, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: false, error: 'internal_error' }));
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
      return json(res, 413, { ok: false, error: String(err.message || err) });
    }
  }

  return json(res, 404, { ok: false, error: 'not_found' });
}

function isValidToken(t) {
  for (const v of tokens.values()) if (v === t) return true;
  return false;
}

function json(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) });
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

process.on('SIGINT', () => {
  console.log('\n[relay] shutting down...');
  wss.close(() => server.close(() => process.exit(0)));
});
