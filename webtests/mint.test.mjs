// ops/mint_scoped_tokens.html (Org & Access M1): the tokens it mints are valid HS256 JWTs with exactly the claims the database checks, and never a `sub`.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createHmac, webcrypto } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { JSDOM } from 'jsdom';

const PAGE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'ops', 'mint_scoped_tokens.html');
const SECRET = 'test-secret-0123456789-abcdefghijklmnopqrstuvwxyz';

function load() {
  const dom = new JSDOM(readFileSync(PAGE, 'utf8'), { runScripts: 'dangerously', beforeParse(w) {
    Object.defineProperty(w, 'crypto', { value: webcrypto }); w.TextEncoder = TextEncoder;
    w.fetch = () => { throw new Error('the minter must not use the network'); };
  } });
  return dom.window;
}
const dec = (s) => JSON.parse(Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString());

test('mints one verifiable token per identity with the claims the database checks', async () => {
  const w = load();
  const now = 1_800_000_000;
  const out = JSON.parse(await w.mintTokens(SECRET, now));
  const ids = Object.keys(out);
  assert.equal(ids.length, 10);
  assert.ok(ids.includes('jarvis') && ids.includes('auditor') && ids.includes('office:ff-marketing:manager'));
  const jtis = new Set();
  for (const [id, tok] of Object.entries(out)) {
    const [h, b, s] = tok.split('.');
    assert.equal(createHmac('sha256', SECRET).update(h + '.' + b).digest('base64url'), s, id + ': signature');
    assert.deepEqual(dec(h), { alg: 'HS256', typ: 'JWT' });
    const c = dec(b);
    assert.equal(c.identity, id);
    assert.equal(c.role, id === 'jarvis' ? 'fz_jarvis' : id === 'auditor' ? 'fz_auditor' : 'fz_office_agent');
    assert.equal(c.iat, now);
    assert.equal(c.exp, now + 180 * 86400);
    assert.ok(!('sub' in c), id + ': no sub claim');
    if (id.startsWith('office:')) assert.equal(c.office, id.split(':')[1]); else assert.ok(!('office' in c));
    jtis.add(c.jti);
  }
  assert.equal(jtis.size, 10, 'every token has its own jti');
});

test('refuses a value that is not a JWT secret', async () => {
  const w = load();
  await assert.rejects(() => w.mintTokens('short', 1), /too short/);
});
