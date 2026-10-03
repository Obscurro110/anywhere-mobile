// Token registry: maps userId -> token
export function parseTokens(raw) {
  const map = new Map();
  for (const pair of String(raw).split(',')) {
    const [uid, tok] = pair.split(':');
    if (uid && tok) map.set(uid.trim(), tok.trim());
  }
  return map;
}

// Reverse lookup: token -> userId (or null)
export function userForToken(tokens, token) {
  for (const [uid, tok] of tokens.entries()) {
    if (tok === token) return uid;
  }
  return null;
}
