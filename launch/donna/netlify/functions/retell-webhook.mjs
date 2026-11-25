// POST /.netlify/functions/retell-webhook : Retell sends each analyzed call here (agent webhook URL, event call_analyzed).
// Verifies Retell's signature, sends the owner a Telegram alert (who, what problem, what fits, booked or not)
// and optionally forwards the same event to a Make.com webhook (texts through Twilio). Never stores anything.
import { verifyRetell, callAlert, sendTelegram, agentAllowed } from '../lib/alert.mjs';

export default async (req) => {
  if (req.method !== 'POST') return new Response('method not allowed', { status: 405 });
  const raw = await req.text();
  if (!verifyRetell(raw, process.env.RETELL_API_KEY, req.headers.get('x-retell-signature'))) {
    return new Response('bad signature', { status: 401 });
  }
  let body;
  try { body = JSON.parse(raw); } catch { return new Response('bad json', { status: 400 }); }
  const call = body?.call || {};
  if (body?.event !== 'call_analyzed' || !agentAllowed(call.agent_id)) return new Response(null, { status: 204 });

  const jobs = [sendTelegram(callAlert(call))];
  const make = process.env.DONNA_MAKE_WEBHOOK_URL;
  if (make) jobs.push(fetch(make, { method: 'POST', headers: { 'content-type': 'application/json' }, body: raw }));
  await Promise.allSettled(jobs);
  return new Response(null, { status: 204 });
};
