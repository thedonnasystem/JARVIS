select cron.schedule('hq-cap-reset-once', '5 5 2 11 *', $$
  update public.system_state set daily_spend_cap_cents = 330 where id = 1 and daily_spend_cap_cents > 330;
  insert into public.audit_log(actor, action, target, detail) values ('system','cap_reset','system_state','{"to_cents":330,"reason":"temporary $15 build-night cap ended"}');
  select cron.unschedule('hq-cap-reset-once');
$$);