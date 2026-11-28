// node --test launch/donna/netlify/alert.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { verifyRetell, callAlert, formAlert, sendTelegram, agentAllowed } from './lib/alert.mjs';

const KEY = 'test_key_not_real';
const sign = (body, ts) => `v=${ts},d=${createHmac('sha256', KEY).update(body + ts).digest('hex')}`;

test('accepts a fresh, correctly signed body', () => {
  const now = 1_800_000_000_000, body = '{"event":"call_analyzed"}';
  assert.equal(verifyRetell(body, KEY, sign(body, now - 1000), now), true);
});

test('rejects tampering, wrong key, stale or malformed signatures', () => {
  const now = 1_800_000_000_000, body = '{"a":1}';
  assert.equal(verifyRetell(body + ' ', KEY, sign(body, now), now), false);
  assert.equal(verifyRetell(body, 'other', sign(body, now), now), false);
  assert.equal(verifyRetell(body, KEY, sign(body, now - 6 * 60 * 1000), now), false);
  assert.equal(verifyRetell(body, KEY, 'v=1,d=zz', now), false);
  assert.equal(verifyRetell(body, '', sign(body, now), now), false);
  assert.equal(verifyRetell(body, KEY, null, now), false);
});

test('call alert shows the qualifying fields and booking', () => {
  const t = callAlert({
    call_type: 'web_call', duration_ms: 154000,
    call_analysis: { call_summary: 'Plumber, misses calls on jobs.', custom_analysis_data: {
      caller_name: 'Sam', business_name: 'Sam Plumbing', main_problem: 'missed calls', solution_fit: 'Capture',
      decision_maker: true, email: 'sam@example.com', booked: true, appointment_time: 'Thu 2pm' } },
  });
  assert.match(t, /Website Donna call/);
  assert.match(t, /Business: Sam Plumbing/);
  assert.match(t, /Fit: Capture/);
  assert.match(t, /Decision maker: yes/);
  assert.match(t, /BOOKED: Thu 2pm/);
  assert.match(t, /Length: 154s/);
  assert.doesNotMatch(t, /Callback/);
});

test('form alert lists fields and drops technical ones', () => {
  const t = formAlert({ form_name: 'contact', data: { name: 'Ana', business: 'Glow Spa', ip: '1.2.3.4', 'bot-field': '', user_agent: 'x' } });
  assert.match(t, /name: Ana/);
  assert.match(t, /business: Glow Spa/);
  assert.doesNotMatch(t, /1\.2\.3\.4|user agent/);
});

test('telegram is skipped when not configured, posts when it is', async () => {
  assert.deepEqual(await sendTelegram('hi', {}), { sent: false, reason: 'telegram not configured' });
  let seen;
  const r = await sendTelegram('hello', { TELEGRAM_BOT_TOKEN: 'T', TELEGRAM_CHAT_ID: '42' }, async (url, init) => { seen = { url, init }; return { ok: true, status: 200 }; });
  assert.equal(r.sent, true);
  assert.equal(seen.url, 'https://api.telegram.org/botT/sendMessage');
  assert.equal(JSON.parse(seen.init.body).chat_id, '42');
});

test('agent filter', () => {
  assert.equal(agentAllowed('agent_a', {}), true);
  assert.equal(agentAllowed('agent_a', { DONNA_AGENT_IDS: 'agent_a, agent_b' }), true);
  assert.equal(agentAllowed('agent_c', { DONNA_AGENT_IDS: 'agent_a,agent_b' }), false);
});
