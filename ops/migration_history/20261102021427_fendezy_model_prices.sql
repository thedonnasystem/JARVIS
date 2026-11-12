
create table public.model_prices (
  model text primary key,
  tier text not null check (tier in ('cheap','standard','strong','premium')),
  input_usd_per_mtok numeric not null,
  output_usd_per_mtok numeric not null,
  long_input_usd_per_mtok numeric,
  long_output_usd_per_mtok numeric,
  long_threshold_tokens int,
  source text not null,
  as_of date not null,
  verified boolean not null default false
);
alter table public.model_prices enable row level security;

insert into public.model_prices (model, tier, input_usd_per_mtok, output_usd_per_mtok, long_input_usd_per_mtok, long_output_usd_per_mtok, long_threshold_tokens, source, as_of, verified) values
 ('claude-haiku-5-5','cheap',0.10,0.50,0.50,2.50,100000,'https://platform.claude.com/docs/en/about-claude/pricing',date '2026-11-01',true),
 ('claude-sonnet-5-5','standard',2,10,null,null,null,'https://platform.claude.com/docs/en/about-claude/pricing',date '2026-11-01',true),
 ('claude-opus-5-5','strong',4,20,null,null,null,'https://platform.claude.com/docs/en/about-claude/pricing',date '2026-11-01',true),
 ('claude-fable-5-1','premium',10,50,null,null,null,'https://platform.claude.com/docs/en/about-claude/pricing',date '2026-11-01',true);

-- USD to CAD is not looked up here; the runtime applies a conservative factor held in system settings until the CFO verifies a rate.
alter table public.system_state add column usd_to_cad numeric not null default 1.45;
alter table public.system_state add column usd_to_cad_verified boolean not null default false;

-- Rough pre-call estimate in cents (CAD), rounded up. Used to reserve budget before the call.
create or replace function public.estimate_call_cents(p_model text, p_input_tokens int, p_max_output_tokens int)
returns int language plpgsql stable set search_path = public as $$
declare m public.model_prices; fx numeric; in_rate numeric; out_rate numeric;
begin
  select * into m from public.model_prices where model = p_model and verified;
  if m.model is null then raise exception 'No verified price for model %. Research must verify it first.', p_model; end if;
  select usd_to_cad into fx from public.system_state where id = 1;
  in_rate := m.input_usd_per_mtok; out_rate := m.output_usd_per_mtok;
  if m.long_threshold_tokens is not null and p_input_tokens > m.long_threshold_tokens then
    in_rate := m.long_input_usd_per_mtok; out_rate := m.long_output_usd_per_mtok;
  end if;
  return greatest(1, ceil(((p_input_tokens * in_rate + p_max_output_tokens * out_rate) / 1000000.0) * fx * 100)::int);
end $$;

select public.estimate_call_cents('claude-sonnet-5-5', 20000, 4000) as sonnet_20k_in_4k_out_cents,
       public.estimate_call_cents('claude-haiku-5-5', 20000, 4000) as haiku_same_call_cents,
       public.estimate_call_cents('claude-opus-5-5', 20000, 4000) as opus_same_call_cents;
