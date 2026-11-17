# Free model providers: terms and limits (checked 2026-11-16, SUBJECT TO CHANGE)

Jarvis's brain costs $0 by default: a rotation of free tiers (`hq_llm.CATALOG`) plus a free self-hosted fallback (`ops/selfhost/`).
Free tiers change their limits, models and terms often. Re-check this page before activation and every few months; the limits in `hq_llm.CATALOG`
are starting values, and the provider's own 429 answers always win (Jarvis backs off and rotates).

Rules the code enforces whatever this page says:
- **Client personal data never goes to a free-tier provider** (enforced in hq_llm from the prompt sources and a personal-data scan, default private: private prompts route only to the owner's self-hosted model, or the task is refused / done in plain code).
- **Providers that train on prompts are excluded** unless the Chairman opts in (`JARVIS_ALLOW_TRAINING_PROVIDERS=1`). None of the catalog entries is marked as training; mark any new one honestly.
- **No silent paid fallback.** When every free provider is at its limit, the work is queued and the Chairman is told.
- Every call, free or not, still passes the spend gateway (kill switch, caps, paused agent).

| Provider | Free offer (as checked) | Training / retention (as checked) | Limits used in code (starting values) | Status of this check |
|---|---|---|---|---|
| Groq (`GROQ_API_KEY`) | Free plan, rate limited | Groq docs ("Your data"): by default does not retain inference request data; inputs/outputs may be logged up to 30 days for reliability / abuse unless you opt out; Zero Data Retention available in Data Controls. The page does not state a training policy: turn ZDR on. | 30 req/min, 1,000 req/day, 6,000 tokens/min (vary per model) | retention: read on Groq's docs page; limits: community / third-party pages, CONFIRM in the Groq console |
| Cerebras (`CEREBRAS_API_KEY`) | NOT a permanent free tier: US$5 trial credits that expire after 30 days | not checked | e.g. 5 req/min, 30k tokens/min for one model (Cerebras rate-limit page) | limits read on Cerebras docs; training NOT verified. Treat as a short trial only |
| OpenRouter `:free` models (`OPENROUTER_API_KEY`) | 50 free-model requests/day; 1,000/day after buying at least 10 credits (US$10, one time) | OpenRouter FAQ: it does not route to providers that log / train unless the account's training toggle is on. Keep it OFF. The code also sends `provider.data_collection = "deny"` (verify the parameter name in the provider-routing docs at activation) | 20 req/min, 50 req/day | daily limits and routing rule read on the OpenRouter FAQ |
| GitHub Models (`GITHUB_MODELS_TOKEN`) | Free, rate limited, for prototyping | NOT verified this session | 10 req/min, 50 req/day (low-tier guess) | UNVERIFIED: check GitHub's docs and terms |
| NVIDIA NIM / build.nvidia.com (`NVIDIA_API_KEY`) | Free developer access, rate limited (trial terms) | NOT verified this session | 40 req/min | UNVERIFIED: check NVIDIA's API trial terms |
| Self-hosted (`JARVIS_SELFHOST_BASE_URL`, `JARVIS_SELFHOST_API_KEY`) | $0 on an always-free CPU VM | your own machine: nothing leaves it | 4 req/min, 4,000 tokens/min (CPU speed) | the only free target for client data |
| Paid, off by default: Anthropic, rented GPU | pay per token / per GPU hour | Anthropic commercial terms (not checked here) | n/a | used only with the self-funded budget and the Chairman's switch |

Anthropic Message Batches (paid provider only): "All usage is charged at 50 percent of the standard API prices", most batches finish within 1 hour, 24-hour limit, results kept 29 days, and the discount stacks with prompt caching (Anthropic docs, batch processing, read 2026-11-16).

Sources read on 2026-11-16: Groq "Your data" (console.groq.com/docs/your-data), OpenRouter FAQ (openrouter.ai/docs/faq), Cerebras rate limits (inference-docs.cerebras.ai/support/rate-limits), Anthropic batch processing (platform.claude.com/docs/en/build-with-claude/batch-processing). Everything marked UNVERIFIED needs a check before relying on it.
