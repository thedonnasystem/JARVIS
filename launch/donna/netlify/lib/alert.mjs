// Shared helpers for the Donna.AI site's Netlify Functions: Retell webhook verification and owner alerts.
// No dependencies (Node 22 built-ins only). Every secret comes from Netlify environment variables the owner sets:
//   RETELL_API_KEY         verifies Retell's webhook signature (Retell signs with the account's API key)
//   TELEGRAM_BOT_TOKEN     the owner's Telegram bot (can be Jarvis's bot)
//   TELEGRAM_CHAT_ID       the owner's chat id with that bot
//   DONNA_AGENT_IDS        optional, comma-separated Retell agent ids to accept (others are ignored)
//   DONNA_MAKE_WEBHOOK_URL optional, a Make.com webhook that also gets each analyzed call (texts via Twilio)
import { createHmac, timingSafeEqual } from 'node:crypto';

const FIVE_MINUTES = 5 * 60 * 1000;

// Retell's scheme (retell-sdk lib/webhook_auth.js): header "v=<ms timestamp>,d=<hex HMAC-SHA256(apiKey, rawBody + timestamp)>", 5-minute window.
export function verifyRetell(rawBody, apiKey, signature, now = Date.now()) {
  if (!apiKey || !signature) return false;
  const m = /^v=(\d+),d=([0-9a-f]{64})$/i.exec(String(signature).trim());
  if (!m) return false;
  const ts = Number(m[1]);
  if (!Number.isSafeInteger(ts) || Math.abs(now - ts) > FIVE_MINUTES) return false;
  const want = createHmac('sha256', apiKey).update(rawBody + m[1]).digest();
  const got = Buffer.from(m[2], 'hex');
  return got.length === want.length && timingSafeEqual(got, want);
}

const clip = (v, n = 400) => {
  const s = v === undefined || v === null ? '' : String(v).replace(/\s+/g, ' ').trim();
  return s.length > n ? s.slice(0, n - 1) + '…' : s;
};

// One plain-text alert for an analyzed call. Only fields that are present are shown.
export function callAlert(call) {
  const a = call?.call_analysis || {};
  const c = a.custom_analysis_data || {};
  const web = call?.call_type === 'web_call' || call?.metadata?.source === 'website';
  const lines = [web ? '🟡 Website Donna call' : '📞 Demo line call'];
  const add = (label, v) => { const s = clip(v); if (s) lines.push(`${label}: ${s}`); };
  add('Name', c.caller_name);
  add('Business', [c.business_name, c.industry].filter(Boolean).join(' · '));
  add('Problem', c.main_problem);
  add('Fit', c.solution_fit);
  add('Team', c.team_size);
  add('Timeline', c.timeline);
  if (typeof c.decision_maker === 'boolean') add('Decision maker', c.decision_maker ? 'yes' : 'no');
  add('Email', c.email);
  add('Callback', c.callback_number || (web ? '' : call?.from_number));
  if (c.booked) add('BOOKED', c.appointment_time || 'yes');
  if (c.urgent) lines.push('⚠️ Marked urgent');
  add('Summary', a.call_summary);
  if (call?.duration_ms) lines.push(`Length: ${Math.round(call.duration_ms / 1000)}s`);
  return lines.join('\n');
}

// One alert for a website form submission (Netlify "submission-created" event).
export function formAlert(payload) {
  const d = payload?.data || {};
  const skip = new Set(['ip', 'user_agent', 'referrer', 'bot-field', 'form-name']);
  const lines = [`📝 New request from the website (${clip(payload?.form_name || d['form-name'] || 'form', 60)})`];
  for (const [k, v] of Object.entries(d)) {
    if (skip.has(k)) continue;
    const s = clip(v);
    if (s) lines.push(`${k.replace(/[_-]+/g, ' ')}: ${s}`);
  }
  return lines.join('\n');
}

export async function sendTelegram(text, env = process.env, fetchImpl = fetch) {
  const token = env.TELEGRAM_BOT_TOKEN, chat = env.TELEGRAM_CHAT_ID;
  if (!token || !chat) return { sent: false, reason: 'telegram not configured' };
  const r = await fetchImpl(`https://api.telegram.org/bot${token}/sendMessage`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ chat_id: chat, text: text.slice(0, 4000), disable_web_page_preview: true }),
  });
  return { sent: r.ok, status: r.status };
}

export function agentAllowed(agentId, env = process.env) {
  const list = (env.DONNA_AGENT_IDS || '').split(',').map((s) => s.trim()).filter(Boolean);
  return list.length === 0 || list.includes(agentId);
}
