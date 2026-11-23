# Linked memory for the open brain

Status: built and tested on a scratch replica. **Off until `JARVIS_LINKED_MEMORY=1` is set in Railway** (it needs the open brain on as well). Nothing is applied to production.

Stacked on PR #49 (open brain). The goal: Jarvis knows the context (people, ventures, offices, decisions) without a big context window or paid tokens.

## 1. What it does

- **Remembers.** Every 6 owner messages, as the oldest turns leave the verbatim window, ONE free-model call reads them together with the 8 most similar memories Jarvis already holds. It answers with JSON operations:
  - `add` a new fact;
  - `update k3` when a known memory changed;
  - `retract k5` when a known memory is now false.
  
  Each fact carries a kind (fact, preference, decision, person, plan, lesson, outcome), an importance (1-5), entities and relations (`["Moe", "decided_focus_for", "Donna"]`).
  - It runs in a background thread: the reply never waits on it.
  - It goes through `hq_llm.complete` (spend gateway first, privacy routing, free providers; `job=bulk`, medium tier).
- **Dedupes.** The database treats an add as a duplicate when the normalised text is already live, or the embedding is at least 0.95 similar to a live row of the same office and class. The existing row is "seen again" (recency, count, importance up).
- **Keeps history.** An update writes a new row and marks the old one `superseded`. A contradiction marks it `retracted`. `/memory forget` marks it `forgotten`. Nothing is deleted.
- **Retrieves.** `jmem_search` scores each live memory as follows:

  | Signal | Weight |
  |---|---|
  | semantic (cosine, same embedder) | 0.50 |
  | lexical (Postgres full text) | 0.20 |
  | importance | 0.15 |
  | recency (`last_seen_at`, ~45-day decay) | 0.10 |
  | a linked entity is named in the message | 0.15 |

  The top 5 go into the lean packet (2 while free quota is low), topped up from the old memory table. That is about 150-300 tokens, inside the 4.8k packet cap.
- **Office memory for missions.** An engine task gets the top 3 memories of its agent's own office. The database derives the office from `agents.office_id`, so a caller cannot pick another office.

## 2. Why native, not a library (evaluated Nov 23 2026, PyPI metadata)

All four were judged by the LiteLLM criteria (OPEN_BRAIN.md 6a): supply chain, import-time network, hidden calls that bypass the spend gateway, and weight.

| Option | License | What it would add | Verdict |
|---|---|---|---|
| mem0 (`mem0ai` 2.2.1) | Apache-2.0 | `openai`, `qdrant-client`, `sqlalchemy`, `posthog` (product telemetry, on by default), `protobuf`, `pydantic`. The graph memory needs Neo4j / Memgraph / Neptune / Kuzu. Its LLM calls go through its own clients. | Not adopted: telemetry in the bot process, second LLM client outside the gateway, graph store = new service |
| Graphiti (`graphiti-core` 0.31.2) | Apache-2.0 | `neo4j` driver + a graph database, `openai`, `posthog`, `tenacity` (own retries); several LLM calls per episode | Not adopted: new paid / hosted service, many calls per message, own retries |
| Letta | Apache-2.0 | a full agent server with its own database schema and agent loop | Not adopted: replaces our loop, a new service |
| LangMem 0.0.30 | MIT | `langchain`, `langgraph`, `langsmith`, `langchain-openai`, `langchain-anthropic` | Not adopted: large dependency tree, LangSmith tracing hooks, direct Anthropic client |

**What was reused:** mem0's design, which is the useful part:

- extract, then compare with the top-k similar memories;
- add / update / delete / no-op decided by the model;
- history kept.

It is re-implemented in about 300 lines of Python plus one migration, on the Postgres we already run. The extraction makes one call (mem0 makes two), and the model sees known memories as short aliases (`k1..k8`), which saves tokens and means it can only touch a memory it was shown.

**No pgvector needed.** Embeddings are 384 small floats in a `real[]`, scored in SQL. That is fine for tens of thousands of memories per office. Moving to pgvector + HNSW later is a column change, not a redesign.

## 3. Embeddings (local only)

- **Default `hash-v1`:** signed feature hashing of words, word pairs and character 4-grams, in pure Python. It has no dependency and no network, and it is deterministic.
  - It is weaker on paraphrases.
  - The lexical and entity parts of the score carry much of the load.
- **Better, optional: fastembed** (Apache-2.0, ONNX on CPU) with `BAAI/bge-small-en-v1.5` (MIT, 384 dimensions). Set `JARVIS_MEMORY_EMBEDDER=fastembed` after the package is added.
  - Adding it changes the protected `requirements.txt`, so it is an owner decision: `ops/proposals/linked_memory_fastembed.md`.
  - If it is missing, the hashed embedder is used.
  - Rows remember which embedder made them; other rows still match on lexical, entity and recency.
- Memory text is never sent to an embedding API.

## 4. Offices and privacy

- Every memory belongs to ONE office (the group or one of the eight, `fz_offices`) and ONE class: `public`, `owner` or `client`.
- An office sees only its own rows. Another office cannot read, update or retract them; such ops are skipped. Entity links across offices are impossible: composite foreign keys `(office_id, id)`.
- The group (owner chat) sees the group's rows and every office's **non-client** rows (the M1 rule: group scope reads all offices except client data).
- **Client rows** are returned only to their own office's self-hosted path (`destination=selfhost`), and that caller must send with `contains_client_data=True`.
  - Never to the group, never to another office, never into an external packet.
  - `/memory` lists them masked.
- **Extraction privacy:**
  - A conversation with client personal data (`hq_llm.data_class`) in the group scope is not sent and not kept.
  - In an office scope, it is extracted only by the self-hosted model (`job=private`, `contains_client_data=True`); with no self-hosted model, nothing is sent.
  - A single fact with personal data is stored as `client`. A missing class is `client` (default deny). The class never goes down on an update.
- **Schema `fz_memory`:** no privilege for any API role (anon, authenticated, service_role, fz_*, backup_reader), RLS on.
  - Only the `jmem_*` / `jquota_*` SECURITY DEFINER functions reach it.
  - They refuse every session role but the bot (service key) and database sessions, in the body, even after a mistaken grant.
  - It is outside the public table registry and the off-site export (like `fz_office_os`, M7).

## 5. Quota counters that survive restarts

`hq_brain_quota` mirrors `hq_llm.TRACKER` (the same object: hq_llm is not changed) to `fz_memory.provider_quota`, which holds 24 hourly slots per provider, reused, and `provider_state` (cool-downs):

- **Load:** before the first open-brain call. It is conservative: restored requests count until their hour ends plus 24 hours.
- **Write:** at most every 15 s, and at once when a cool-down changes.
- **Database down:** one retry per 5 minutes; model calls never wait on it.

**Graceful degradation:**

- When the best free provider of the chat route is under 15% of today's quota:
  - one heads-up line on a reply, at most every 30 minutes;
  - the packet carries 2 memories instead of 5.
- When every provider is at its limit, the exhausted reply now says when free capacity returns ("in about 25 min"), worked out from cool-downs and the day windows.

`/brainstatus` shows whether the counters are persisted and whether linked memory is on.

## 6. Owner commands (`/memory`, owner only, no AI)

```
/memory                     newest memories (group)
/memory donna               one office (b2b-records, donna, the-trap, wolf-squad, pimp-ai, monopoly, ff-marketing, fruition-factory)
/memory find hvac           search
/memory links Moe           what a person / venture / office is linked to
/memory forget 1a2b3c4d     forget one (first 8 characters of the id)
/memory forget about Jane   forget everything linked to a name
/memory stats               counts per office and class
```

Forget is soft: never retrieved again, kept as history, audited with ids and counts only.

## 7. Not changed

- `hq_llm.py`, `bot.py`, `hq_engine.py`, the $3.30 cap, the kill switch, the spend gateway, `authorize_action`, `llm_calls` and every money table are unchanged.
- Anthropic stays off.
- The sqltest money fingerprint is identical with the migration, after its rollback (twice) and after a re-apply.
- The changed files are:
  - `hq_open_brain.py` (PR #49's module): the hooks;
  - `hq_commands.py`: one owner command.

## 8. Rollback

- **Code:** unset `JARVIS_LINKED_MEMORY` in Railway. This is instant: packet memory and extraction go back to PR #49 behaviour.
  - `JARVIS_QUOTA_PERSIST=0` turns the counter persistence off.
- **Database:** `ops/rollback_linked_memory.sql` drops the functions and renames `fz_memory` to `fz_memory_archive` (no API privileges). Nothing is deleted, and re-applying the migration restores it.
  - It is independent of `rollback_open_brain.sql`; either order works.

## 9. Risks / limits

- **Free small models extract imperfectly.**
  - Mitigations: the medium tier, strict JSON parsing, aliases, clamping, and DB-side dedupe.
  - Wrong facts can be removed with `/memory forget`.
- **Hashed embeddings are lexical-ish.** fastembed is the quality upgrade (owner decision).
- **Group scope reads offices' non-client memories** (M1 policy). If the owner wants strict silos even for the group, it is a one-line change in `jmem_search`.
- **Extraction lags the conversation** by up to about 12 messages. Until then the turns are still in the verbatim window, so nothing is lost.
- **Mission outputs are not yet extracted into office memory.** The API supports it (`hq_memory.extract(..., agent=slug)`); wiring it into `hq_engine` touches a money-category file (owner approval).

## 10. Test evidence

- `test_hq_memory.py`: 26 tests, network and database mocked. They cover:
  - the embedder;
  - extraction through the real `hq_llm.complete`, which takes in privacy routing: group client data is never sent; office client data goes to selfhost only; with no selfhost nothing is sent; a known client memory forces selfhost;
  - aliases;
  - classing;
  - garbage and exhausted answers;
  - a gateway refusal re-raised;
  - packet retrieval never asks for client rows;
  - `/memory`, owner only;
  - quota: restart, cool-down, throttle, dead database, exhausted text, heads-up;
  - the open-brain hooks, both off and on.
- `sqltests/linked_memory_check.sql`, sections L1-L8:
  - privileges;
  - the body guard;
  - office isolation, including the agent pin and the cross-office foreign key;
  - client scoping;
  - class monotonicity;
  - dedupe (exact and near);
  - update history, retract, forget and its audit;
  - links;
  - quota slots and validation;
  - rollback twice plus re-apply, with the money fingerprint identical and the rows kept.
