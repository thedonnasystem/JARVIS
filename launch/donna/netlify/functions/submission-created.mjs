// Netlify event function: runs automatically on every verified Netlify Forms submission (the site's contact form).
// Sends the owner a Telegram alert so a consultation request is seen in minutes, not hours.
import { formAlert, sendTelegram } from '../lib/alert.mjs';

export default async (req) => {
  let body;
  try { body = await req.json(); } catch { return new Response(null, { status: 204 }); }
  await sendTelegram(formAlert(body?.payload)).catch(() => {});
  return new Response(null, { status: 204 });
};
