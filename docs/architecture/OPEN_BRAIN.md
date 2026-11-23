# Open brain: owner chat and missions on free open models

Status: built and tested on a scratch replica. **Off until `JARVIS_OPEN_BRAIN=1` is set in Railway.** Nothing is applied to production.

## 1. What was built

- **One router for every model call** (`hq_llm.complete(..., job=...)`). Each job type has its own fallback chain; past the end of the chain the work is queued (`EXHAUSTED_REPLY`), and nothing is spent.

  | Job | Chain | Tier | Who may see it |
  |---|---|---|---|
  | `chat` (owner chat, tools) | groq → cerebras → openrouter → selfhost → selfhost2 → anthropic (paid, off) | medium | owner data: needs the owner switch |
  | `long` (big inputs, research) | gemini → openrouter → cerebras | medium | non-private only for gemini |
  | `reason` (hard planning) | groq gpt-oss-120b → openrouter DeepSeek R1 :free → cerebras gpt-oss-120b → gemini | reason | as its data class allows |
  | `private` (client data) | selfhost (Oracle Ollama) → selfhost2 (owner's Mac Ollama) → gpu | medium | client data: self-hosted only |
  | `bulk` (background) | whoever has the most quota left (free first) | small | as its data class allows |

  - Owner chat uses `chat`. Mission tasks use `bulk`, or `reason` for strong-tier agents.
  - The chat's research agent uses `chat` and its content agent uses `chat`.
  - The rolling summary uses `bulk`.
- **Privacy is decided from the declared sources and a content scan**, never from the job.
  - The job only orders providers; it never widens who may see a prompt.
- **New providers** (code-only catalog, loaded only when `JARVIS_OPEN_BRAIN=1`):
  - **Google Gemini free** (`GEMINI_API_KEY`): `trains=True`.
  - **Cloudflare Workers AI** (`CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`): `trains=False`. Cloudflare states it does not use customer content to train models. It makes no zero-retention commitment, so it takes public prompts only.
  - **A second self-hosted endpoint** (`JARVIS_SELFHOST2_BASE_URL`, `JARVIS_SELFHOST2_API_KEY`) for the owner's Mac running Ollama.
- **Tool calling in OpenAI format** for every OpenAI-compatible provider.
  - It is converted for Anthropic when Anthropic is ever used.
  - A provider whose tool call is malformed (an unknown tool, or arguments that are not a JSON object) is skipped like a failed provider, so the next one is tried.
- **Lean packet for owner chat.**
  - Target is 3–4k tokens. The hard cap is `FREE_PROMPT_TOKENS` (6,000) minus the reply budget (1,000 output) minus a 200 margin, giving 4,800 input tokens.
  - Each packet carries a compact system prompt (or `JARVIS_FREE_SYSTEM_PROMPT`), a rolling summary of older turns (refreshed every 6 messages by the small tier), the top 5 memory facts (public kinds only), the last 6 messages and the owner's message.
  - **Tool definitions are attached only when the message asks for an action**: a cheap intent check, then at most 6 compacted tools ranked by relevance.
  - Tool rounds are trimmed to stay under the cap.
  - The packet size is logged on every call and shown by `/brainstatus`.
- **Response cache:** identical public, tool-less job prompts are answered from an in-process cache (`JARVIS_LLM_CACHE_TTL`, default 600 s) with no model call and no gateway reservation.
- **Health and headroom tracking.** Each provider's requests per minute, requests per day and tokens per minute are tracked, a provider that errors cools down, and quota left today is computed.
  - Chains demote providers with less than 10% quota left.
  - `bulk` takes the provider with the most quota left.
- **`/brainstatus`** (owner command) shows:
  - the provider, model and packet size of the last answer;
  - each job's route and the next provider it would use;
  - each provider's state (ready or cooling) and quota left;
  - both owner switches.

## 2. The owner's decisions (default OFF)

`ops/OWNER_OPEN_BRAIN.sql`, run in the Supabase SQL editor:

1. **`owner_chat_free_providers`**: lets your chat and your missions go to free providers that do not train on prompts and keep no prompt data. These are Groq, OpenRouter (every request sent with `data_collection: deny`) and Cerebras.
   - While it is off, your chat can only use a self-hosted model or (if you switched paid on) Anthropic. Otherwise Jarvis tells you and sends nothing.
2. **`allow_training_providers_nonprivate`**: lets Gemini (whose free tier may train on prompts) take **non-private** work only: public sources, with nothing personal detected.
   - Your chat and client data never go there, whatever this says.

**Client data**, meaning client sources or anything the `hq_scrub` / `pii_hit` detectors find, **goes only to the self-hosted models, whatever either switch says.**
- A fetched credential is withheld from every model provider.

## 3. Privacy matrix (tested in `test_open_brain.PrivacyMatrix`)

| Data class | groq / cerebras / openrouter | github / nvidia / cloudflare | gemini | selfhost / selfhost2 | anthropic |
|---|---|---|---|---|---|
| public | yes | yes | only with switch 2 | yes | only if paid is on |
| owner, switch 1 off | no | no | no | yes | only if paid is on |
| owner, switch 1 on | yes | no | no | yes | only if paid is on |
| client | no | no | no | yes | no |

## 4. Not changed

- The $3.30 daily cap, the kill switch, dry_run and mode, `authorize_action`, `action_policy` and every money control are unchanged.
- Every call still reserves through `reserve_llm_budget` first. Free calls reserve and settle 0 cents. The sqltest's money fingerprint is identical with the migration, after its rollback and after a re-apply.
- **Anthropic is the last resort and off.** `hq_llm` uses it only when `jarvis_self_fund_status` says paid is allowed: the owner's `paid_providers_enabled` plus a self-funded budget with money left.
- **Default is today's behaviour.** With `JARVIS_OPEN_BRAIN` unset, the bot and the engine use the existing direct Anthropic path, byte for byte. The existing spend and bypass tests pin that path, and changing them needs your approval.
  - Turning the open brain on is one Railway variable. Unsetting it is the instant rollback.

## 5. Rollback

- **Code:** unset `JARVIS_OPEN_BRAIN` in Railway.
- **Database:** run `ops/rollback_open_brain.sql`, before `rollback_monitoring_brain.sql`. It keeps both switch values in one audit_log row, then drops the two columns and the three functions.

## 6. Limits and risks

- **No web search** on free models: the research agent says when an answer is not web-verified, and mission research tasks lose Anthropic's web search tool.
- **Free tiers change their terms and model ids often.** Every model id can be overridden without code (`JARVIS_<PROVIDER>_MODEL_SMALL/_MEDIUM/_REASON`), and so can every prompt budget (`JARVIS_<PROVIDER>_MAX_PROMPT_TOKENS`). Confirm the model ids at activation (`check_tool_calling`).
- **Rate counts are in memory**, so a restart forgets them. The providers' own 429 responses still apply, and the router rotates on them.
- **Tool results that contain client personal data stop the chat turn** (client class); the reply says so. That is deliberate.
- **The chat summary is stored in the bot's `memory` table** (category `chat_summary`). Summaries go through the same privacy routing as the chat.

## 6a. Why not LiteLLM (evaluated Nov 22 2026, not adopted)

LiteLLM (MIT, latest 1.110.2) was evaluated as the transport, fallback and retry layer under `hq_llm`. It was **not adopted inside the bot process**, for four reasons:

- **Supply-chain record.** In March 2026, LiteLLM's release pipeline was compromised: PyPI 1.82.7 and 1.82.8 shipped a credential stealer that ran on interpreter start-up (TeamPCP campaign; see oss-security, 2026-03-24 and 03-25). `hq_llm` runs in the same process as the Telegram token, the Supabase service key and the Bitwarden session. Version pinning plus hash locking guards against a re-published wheel, but not against a pinned version that was bad from the start. Every future upgrade would also need a security review.
- **Weight.** It adds 17 new runtime packages to the hashed lock (31 MB of wheels), among them openai, tiktoken, tokenizers (a native binary), huggingface-hub, hf-xet, jinja2, regex and fsspec. That roughly triples the attack surface of the runtime lock, which today has 59 packages.
- **Hidden network and behaviour.** It fetches a remote model-price map at import unless that is disabled, it has callback and telemetry hooks, and its own retries and fallbacks can make a second provider call that the spend gateway did not reserve. Our gateway has to see every attempt.
- **Little to gain.** The existing rotation, built with the standard library and already in this PR, covers what we use LiteLLM for:
  - OpenAI-compatible transport for every provider;
  - the Anthropic conversion;
  - rate windows, cool-downs and headroom;
  - rotation on 429 or error, and on a malformed tool call;
  - per-provider budgets.

  Mutation tests cover it, at about 300 lines. Every provider we use speaks the OpenAI format natively, which is the hard part LiteLLM abstracts.

If a provider that does not speak the OpenAI format is ever needed, the safe route is to run the LiteLLM proxy as a separate, credential-isolated service (its own container, holding only the LLM keys) and register it as one more OpenAI-compatible endpoint. Privacy routing and the gateway would stay in `hq_llm`.

## 7. Owner key list (free sign-ups; paste each value into Railway → the bot service → Variables, nowhere else)

1. **`JARVIS_OPEN_BRAIN`** = `1` turns the open brain on.
2. **`GROQ_API_KEY`**
   1. Go to https://console.groq.com and sign in (Google, GitHub or email).
   2. Open **API Keys**, then **Create API Key**, name it `jarvis`, and copy it. It is shown once.
   3. Free tier; no card needed.
3. **`OPENROUTER_API_KEY`**
   1. Go to https://openrouter.ai and sign in.
   2. Open **Settings → Keys** (https://openrouter.ai/settings/keys), then **Create Key**, and copy it.
   3. Do **not** buy credits.
   4. Jarvis only uses `:free` models and sends `data_collection: deny` on every request. Under **Settings → Privacy**, keep "allow providers that may train on inputs" off as well.
4. **`CEREBRAS_API_KEY`**
   1. Go to https://cloud.cerebras.ai and sign up.
   2. Open **API Keys**, then **Generate API Key**, and copy it.
5. **`GEMINI_API_KEY`** (optional; used only for non-private work, and only after you turn switch 2 on)
   1. Go to https://aistudio.google.com/apikey.
   2. Click **Create API key** and copy it.
   3. Do not attach a billing account. It stays on the free tier.
6. **`CLOUDFLARE_ACCOUNT_ID`** and **`CLOUDFLARE_API_TOKEN`** (optional backup)
   1. Go to https://dash.cloudflare.com and sign up on the free plan.
   2. Copy the **Account ID** from the account home page, in the right-hand panel under API.
   3. Open **My Profile → API Tokens → Create Token**, use the **Workers AI** template, and create and copy the token.
7. **`GITHUB_MODELS_TOKEN`** (optional)
   1. Go to https://github.com/settings/personal-access-tokens and choose **Generate new token** (fine-grained).
   2. Under **Permissions → Models**, set **Read-only**, then generate and copy the token.
8. **`NVIDIA_API_KEY`** (optional)
   1. Go to https://build.nvidia.com and sign in.
   2. Open any model and click **Get API Key**, then copy the key (it starts with `nvapi-`).
9. **Optional self-hosted endpoints:**
   - `JARVIS_SELFHOST_BASE_URL` and `JARVIS_SELFHOST_API_KEY` (Oracle VM, ops/selfhost/).
   - `JARVIS_SELFHOST2_BASE_URL` (your Mac's Ollama `…/v1` behind a private tunnel) and `JARVIS_SELFHOST2_API_KEY` (any value; Ollama ignores it).

Then run `ops/OWNER_OPEN_BRAIN.sql` (switch 1), and optionally switch 2.

## 8. Test evidence

- `test_open_brain.py` covers:
  - failover;
  - the exhausted reply;
  - Anthropic used only as the last resort and only when paid is on;
  - no provider call after a gateway refusal;
  - the tool round trip, plus OpenAI-to-Anthropic conversion;
  - rotation past broken tool calls;
  - the privacy matrix;
  - every route (chat, long, reason, private, bulk by quota left);
  - the response cache (public only; a cache hit makes no gateway call);
  - the lean packet: the cap is never exceeded, plain chat sends no tools, at most 6 compact tools and the named tool comes first, the summary and memory are used, tool rounds are trimmed, the summary refreshes, and the packet size is logged;
  - the bot loop: a tool round with the credential withheld, the exhausted, refused and kill-switch replies, and the budget status;
  - the engine path, booked to the agent with its purpose;
  - `/brainstatus`.
- `sqltests/open_brain_check.sql` covers:
  - both switches default off;
  - the owner only (the bot is refused, by function or direct write, even with RLS bypassed);
  - auditing;
  - the rollback, run twice, followed by a re-apply;
  - an identical money fingerprint.
- Mutation tests on the routing gates: 31 mutants (client and owner pool filters, switch fail-closed, data classification, training gating, paid gating, tool-call validation, chain and headroom ordering, the cache class, prompt budgets, the gateway, the packet cap, tool selection, the summary, tool-round trimming, credential withholding, the default-off flag).
  - 30 were killed.
  - The one survivor ("training switch applied to owner data") is equivalent: the owner filter independently excludes every training provider, and a test proves that.
