import { timingSafeEqual } from 'node:crypto';

/**
 * Token registry: maps userId -> token
 *
 * ⚠️ 安全约定：
 *   · 令牌比较必须用**时序安全**比较，否则可以用响应耗时逐字节爆破 token；
 *   · 拒绝默认占位值（CHANGE_ME_TOKEN），防止部署时忘记改。
 */

/** 明确禁止的占位/弱值 */
const FORBIDDEN_TOKENS = new Set([
  'change_me_token',
  'change-me-token',
  'changeme',
  'token',
  'password',
  '123456',
  'test',
]);

/** 最短长度：公网服务，太短的 token 可爆破 */
const MIN_TOKEN_LEN = 16;

export function parseTokens(raw) {
  const map = new Map();
  for (const pair of String(raw).split(',')) {
    const idx = pair.indexOf(':');
    if (idx <= 0) continue;
    const uid = pair.slice(0, idx).trim();
    const tok = pair.slice(idx + 1).trim();
    if (!uid || !tok) continue;
    map.set(uid, tok);
  }
  return map;
}

/**
 * 校验令牌配置。
 *
 * 返回 { fatal, warn }：
 *   · fatal：**必须**修，否则拒绝启动（默认占位 token / 空配置 —— 这类等于没设防）
 *   · warn ：只警告、照常启动（例如 token 偏短 —— 避免升级时把线上打挂）
 */
export function validateTokenConfig(tokens) {
  const fatal = [];
  const warn = [];
  if (!tokens || tokens.size === 0) {
    fatal.push('AUTH_TOKENS 为空');
    return { fatal, warn };
  }
  for (const [uid, tok] of tokens.entries()) {
    if (FORBIDDEN_TOKENS.has(tok.toLowerCase())) {
      fatal.push(`用户 ${uid} 仍在使用默认占位 token（等于没设防），必须修改`);
      continue;
    }
    if (tok.length < MIN_TOKEN_LEN) {
      warn.push(`用户 ${uid} 的 token 偏短（${tok.length} 字符，建议至少 ${MIN_TOKEN_LEN}）`);
    }
  }
  return { fatal, warn };
}

/** 时序安全比较（长度不同也走一次固定比较，避免长度侧信道） */
function safeEqual(a, b) {
  const ba = Buffer.from(String(a), 'utf8');
  const bb = Buffer.from(String(b), 'utf8');
  if (ba.length !== bb.length) {
    // 仍然做一次比较，避免"长度不等就立即返回"造成的时序差异
    timingSafeEqual(ba, ba);
    return false;
  }
  return timingSafeEqual(ba, bb);
}

/**
 * Reverse lookup: token -> userId (or null)
 *
 * 注意：这里会对**所有**用户都比较一遍（不提前 break），
 * 让耗时与"命中了第几个用户"无关。
 */
export function userForToken(tokens, token) {
  if (!token) return null;
  let hit = null;
  for (const [uid, tok] of tokens.entries()) {
    if (safeEqual(tok, token)) hit = uid;
  }
  return hit;
}
