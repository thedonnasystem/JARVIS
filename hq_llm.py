"""
Provider-neutral model access for Jarvis core v2 (cost engine). DORMANT: the running bot does not call this until the owner activates the core.

Chairman's rule (Nov 16 2026): the brain costs $0 by default.
  * A ROTATION of free-tier, OpenAI-compatible providers (Groq, Cerebras trial, OpenRouter ':free' models, GitHub Models, NVIDIA NIM) plus a FREE self-hosted
    fallback (a small quantized Hermes / Qwen model on an always-free CPU VM via llama.cpp or Ollama, ops/selfhost/). A provider is used only when its key is set.
  * Providers whose free tier trains on prompts are excluded unless the owner opts in (JARVIS_ALLOW_TRAINING_PROVIDERS=1).
  * Client personal data (contains_client_data=True) NEVER goes to a free-tier provider: only to a provider marked client_data_ok (the owner's own self-hosted
    model) or it is handled by plain code. With no such provider the call is refused.
  * Per-provider rate tracking (requests/min, requests/day, tokens/min) with backoff on 429 / errors and rotation to the next provider.
  * When every provider is exhausted: AllProvidersExhausted. The caller queues the work (enqueue_batch) and tells the Chairman plainly (EXHAUSTED_REPLY).
  * Paid providers (Anthropic, a rented GPU pod) are configurable but OFF: they are eligible only when the owner set paid_providers_enabled AND the
    self-funded budget (owner-set percentage of owner-confirmed, bank-matched Jarvis revenue) has money left (jarvis_self_fund_status). Never a silent switch.
Every attempt, free or paid, goes through the existing spend gateway first (hq_meter -> reserve_llm_budget: kill switch, caps, paused agent, mission budget).
Free calls settle at 0 cents. The cap values are never changed here.

Environment (names only; values live in Railway Variables, never in the repo). For each provider NAME in the catalog:
  <KEY ENV of the provider>              e.g. GROQ_API_KEY, CEREBRAS_API_KEY, OPENROUTER_API_KEY, GITHUB_MODELS_TOKEN, NVIDIA_API_KEY, JARVIS_SELFHOST_API_KEY
  JARVIS_<NAME>_MODEL_SMALL / _MEDIUM / _LARGE   override the catalog's model ids (confirm current ids at activation: free model lists change often)
  JARVIS_SELFHOST_BASE_URL               the self-hosted endpoint (https, or http only for localhost)
  JARVIS_GPU_BASE_URL / JARVIS_GPU_API_KEY / JARVIS_GPU_USD_PER_HOUR   optional rented GPU pod (paid, gpu_hour metering)
  JARVIS_LLM_ORDER                       comma list, default "groq,cerebras,openrouter,github,nvidia,selfhost,gpu,anthropic"
  JARVIS_LLM_EXTRA_PROVIDERS             JSON list of extra provider dicts (same fields as CATALOG)
  JARVIS_ALLOW_TRAINING_PROVIDERS        1 = owner opted in to providers that train on prompts (default off)
"""
from __future__ import annotations

import hashlib
import json
import logging
import math
import os
import time
import urllib.error
import urllib.parse
import urllib.request

import hq
import hq_meter

logger = logging.getLogger(__name__)

CORE_AGENT = "jarvis-core"
TIERS = ("small", "medium", "large")
MAX_PROMPT_TOKENS = 90_000          # hard ceiling (some paid prices jump above 100k input tokens)
FREE_PROMPT_TOKENS = 6_000          # what a free-tier call may carry: free tokens-per-minute limits are small, so prompts stay small (retrieval, not dumps)
CHARS_PER_TOKEN = 3.5               # conservative: over-counts tokens
MEDIUM_CLASSES = frozenset({"contract.review", "legal.check", "code.write", "code.review", "mission.plan", "selfedit.author", "selfedit.review"})
OFFLINE_REPLY = ("My brain is offline right now, sir: no model provider is reachable. Plain commands still work (/hq, /kill, /resume, /money, /missions, /core). "
                 "Nothing was spent and I did not switch to a paid provider.")
EXHAUSTED_REPLY = ("Sir, every free model provider is at its limit right now. I queued the work and will run it when a free provider is available again. "
                   "Nothing was spent and I did not switch to a paid provider.")
CLIENT_DATA_REPLY = ("Sir, that task contains client personal data, and no self-hosted model is set up, so I will not send it to a free provider. "
                     "It needs plain code or the self-hosted model (ops/selfhost/).")

# Terms and limits: see FREE_PROVIDER_TERMS.md (checked Nov 16 2026, SUBJECT TO CHANGE). Model ids are defaults to be confirmed at activation.
CATALOG = [
    {"name": "groq", "base_url": "https://api.groq.com/openai/v1", "key_env": "GROQ_API_KEY", "paid": False, "trains": False, "client_data_ok": False,
     "models": {"small": "llama-3.1-8b-instant", "medium": "llama-3.3-70b-versatile"}, "limits": {"rpm": 30, "rpd": 1000, "tpm": 6000}},
    {"name": "cerebras", "base_url": "https://api.cerebras.ai/v1", "key_env": "CEREBRAS_API_KEY", "paid": False, "trains": False, "client_data_ok": False, "trial": True,
     "models": {"small": "qwen-3.8-27b", "medium": "gpt-oss-120b"}, "limits": {"rpm": 5, "rpd": 1000, "tpm": 30000}},
    {"name": "openrouter", "base_url": "https://openrouter.ai/api/v1", "key_env": "OPENROUTER_API_KEY", "paid": False, "trains": False, "client_data_ok": False,
     "models": {"small": "nousresearch/hermes-3-llama-3.1-405b:free", "medium": "nousresearch/hermes-3-llama-3.1-405b:free"}, "limits": {"rpm": 20, "rpd": 50, "tpm": 20000},
     "extra_body": {"provider": {"data_collection": "deny"}}},
    {"name": "github", "base_url": "https://models.github.ai/inference", "key_env": "GITHUB_MODELS_TOKEN", "paid": False, "trains": False, "client_data_ok": False,
     "models": {"small": "openai/gpt-4.1-mini", "medium": "openai/gpt-4.1"}, "limits": {"rpm": 10, "rpd": 50, "tpm": 8000}},
    {"name": "nvidia", "base_url": "https://integrate.api.nvidia.com/v1", "key_env": "NVIDIA_API_KEY", "paid": False, "trains": False, "client_data_ok": False,
     "models": {"small": "meta/llama-3.1-8b-instruct", "medium": "meta/llama-3.3-70b-instruct"}, "limits": {"rpm": 40, "rpd": 1000, "tpm": 20000}},
    {"name": "selfhost", "base_url_env": "JARVIS_SELFHOST_BASE_URL", "key_env": "JARVIS_SELFHOST_API_KEY", "paid": False, "trains": False, "client_data_ok": True,
     "models": {"small": "hermes-8b-q4", "medium": "hermes-8b-q4"}, "limits": {"rpm": 4, "rpd": 2000, "tpm": 4000}, "timeout": 600},
    {"name": "gpu", "base_url_env": "JARVIS_GPU_BASE_URL", "key_env": "JARVIS_GPU_API_KEY", "paid": True, "trains": False, "client_data_ok": True, "metering": "gpu_hour",
     "models": {"small": "hermes-70b-awq", "medium": "hermes-70b-awq"}, "limits": {"rpm": 60, "rpd": 20000, "tpm": 200000}},
    {"name": "anthropic", "base_url": "https://api.anthropic.com", "key_env": "ANTHROPIC_API_KEY", "paid": True, "trains": False, "client_data_ok": False, "kind": "anthropic",
     "models": {"small": "claude-haiku-5-5", "medium": "claude-sonnet-5-5", "large": "claude-opus-5-5"}, "limits": {"rpm": 50, "rpd": 5000, "tpm": 100000}},
]
DEFAULT_ORDER = "groq,cerebras,openrouter,github,nvidia,selfhost,gpu,anthropic"


class BrainOffline(Exception):
    """No model can be used. Safe to show the owner."""


class AllProvidersExhausted(BrainOffline):
    """Every eligible provider is rate limited or failing: queue the work."""


class ClientDataRefused(BrainOffline):
    pass


class PromptTooLarge(Exception):
    pass


class MissionStopped(Exception):
    """Budget, step limit, loop or no progress. Stopped before spending more."""


class LargeTierRefused(Exception):
    pass


# ------------------------------------------------------------------------------------------------------------------- providers
class Provider:
    def __init__(self, spec: dict, env: dict):
        self.spec = spec
        self.name = spec["name"]
        self.kind = spec.get("kind", "openai_compat")
        self.base_url = (env.get(spec["base_url_env"], "") if spec.get("base_url_env") else spec.get("base_url", "")).strip().rstrip("/")
        self.key = (env.get(spec["key_env"]) or "").strip()
        self.paid, self.trains, self.client_data_ok = bool(spec.get("paid")), bool(spec.get("trains")), bool(spec.get("client_data_ok"))
        self.models = {t: (env.get(f"JARVIS_{self.name.upper()}_MODEL_{t.upper()}") or spec.get("models", {}).get(t) or "").strip() for t in TIERS}
        self.limits = dict(spec.get("limits") or {})
        self.metering = spec.get("metering", "tokens")
        self.extra_body = spec.get("extra_body") or {}
        self.timeout = int(spec.get("timeout") or 120)
        try:
            self.gpu_usd_per_hour = float(env.get("JARVIS_GPU_USD_PER_HOUR") or 0) if self.metering == "gpu_hour" else 0.0
        except ValueError:
            self.gpu_usd_per_hour = 0.0
        try:
            self.prices = json.loads(env.get("JARVIS_LLM_PRICES") or "{}")
        except ValueError:
            self.prices = {}

    def problems(self) -> list[str]:
        out = []
        if not self.base_url:
            out.append(f"{self.name}: no endpoint ({self.spec.get('base_url_env')})")
        else:
            u = urllib.parse.urlparse(self.base_url)
            if u.scheme != "https" and not (u.scheme == "http" and u.hostname in ("localhost", "127.0.0.1", "::1")):
                out.append(f"{self.name}: endpoint must use https (plain http only for localhost)")
        if not self.key:
            out.append(f"{self.name}: {self.spec['key_env']} not set")
        if not self.models["small"]:
            out.append(f"{self.name}: no model")
        if self.metering == "gpu_hour" and self.gpu_usd_per_hour <= 0:
            out.append(f"{self.name}: JARVIS_GPU_USD_PER_HOUR not set")
        return out

    def model(self, tier: str) -> str:
        return self.models.get(tier) or (self.models.get("medium") if tier == "large" else "") or self.models.get("small") or ""


def load_providers(env: dict | None = None) -> list[Provider]:
    e = os.environ if env is None else env
    specs = {s["name"]: s for s in CATALOG}
    try:
        for s in json.loads(e.get("JARVIS_LLM_EXTRA_PROVIDERS") or "[]"):
            if isinstance(s, dict) and s.get("name") and (s.get("base_url") or s.get("base_url_env")) and s.get("key_env"):
                specs[str(s["name"])] = s
    except ValueError:
        logger.warning("JARVIS_LLM_EXTRA_PROVIDERS is not valid JSON; ignored")
    order = [n.strip() for n in (e.get("JARVIS_LLM_ORDER") or DEFAULT_ORDER).split(",") if n.strip()]
    order += [n for n in specs if n not in order]
    return [Provider(specs[n], e) for n in order if n in specs]


def eligible(providers: list[Provider], *, contains_client_data: bool, paid_allowed: bool, allow_training: bool) -> list[Provider]:
    out = []
    for p in providers:
        if p.problems():
            continue                                  # not configured
        if p.trains and not allow_training:
            continue                                  # trains on prompts: owner has not opted in
        if p.paid and not paid_allowed:
            continue                                  # $0 stack: paid only with the self-funded budget and the owner's switch
        if contains_client_data and not p.client_data_ok:
            continue                                  # client personal data never goes to a free-tier provider
        out.append(p)
    return out


# ------------------------------------------------------------------------------------------------------------------- rate limits
class RateTracker:
    """In-process sliding windows per provider (requests/min, requests/day, tokens/min) plus a cool-down after 429 / failures.
    In memory only: a restart forgets the counts and the provider's own 429s take over (stated in the owner guide)."""

    def __init__(self, clock=time.time):
        self.clock = clock
        self.req: dict[str, list[float]] = {}
        self.tok: dict[str, list[tuple[float, int]]] = {}
        self.cool: dict[str, float] = {}
        self.fails: dict[str, int] = {}

    def allows(self, p: Provider, tokens: int) -> bool:
        now = self.clock()
        if self.cool.get(p.name, 0) > now:
            return False
        r = [t for t in self.req.get(p.name, []) if t > now - 86400]
        self.req[p.name] = r
        tk = [(t, n) for t, n in self.tok.get(p.name, []) if t > now - 60]
        self.tok[p.name] = tk
        lim = p.limits
        if lim.get("rpd") and len(r) >= lim["rpd"]:
            return False
        if lim.get("rpm") and sum(1 for t in r if t > now - 60) >= lim["rpm"]:
            return False
        if lim.get("tpm") and sum(n for _, n in tk) + tokens > lim["tpm"]:
            return False
        return True

    def record(self, p: Provider, tokens: int) -> None:
        now = self.clock()
        self.req.setdefault(p.name, []).append(now)
        self.tok.setdefault(p.name, []).append((now, int(tokens)))
        self.fails[p.name] = 0

    def penalize(self, p: Provider, retry_after: float | None = None) -> float:
        n = self.fails.get(p.name, 0) + 1
        self.fails[p.name] = n
        wait = retry_after if retry_after and retry_after > 0 else min(3600.0, 30.0 * (2 ** (n - 1)))
        self.cool[p.name] = self.clock() + wait
        return wait

    def status(self) -> dict:
        now = self.clock()
        return {n: {"cooling_s": max(0, int(c - now))} for n, c in self.cool.items() if c > now}


TRACKER = RateTracker()


# ------------------------------------------------------------------------------------------------------------------- routing
def choose_tier(task_class: str, quality_failed: bool = False, large_approval: str | None = None, mission_id: str | None = None, use_approval=None) -> str:
    """small by default; medium when a quality check failed or the class needs it; large ONLY with an owner approval the database accepts (single use)."""
    if large_approval:
        if use_approval is None:
            use_approval = lambda a, m: bool(hq._request("POST", "/rest/v1/rpc/jarvis_use_large_approval", {"p_id": a, "p_mission": m}))
        if not use_approval(large_approval, mission_id):
            raise LargeTierRefused("the large model tier needs a valid, unused owner approval (jarvis_owner_approve_large)")
        return "large"
    if quality_failed or task_class in MEDIUM_CLASSES:
        return "medium"
    return "small"


def self_fund_status() -> dict:
    """The database's answer (jarvis_self_fund_status). Unreachable = no paid use (fail closed)."""
    try:
        return hq._request("POST", "/rest/v1/rpc/jarvis_self_fund_status", {}) or {}
    except Exception:
        return {"paid_allowed": False}


# ------------------------------------------------------------------------------------------------------------------- prompts
def estimate_tokens(text: str) -> int:
    return int(math.ceil(len(text or "") / CHARS_PER_TOKEN))


def build_messages(identity: str, core_memory: str, retrieved: list[str], task: str, max_tokens: int = FREE_PROMPT_TOKENS, max_output: int = 800):
    """Stable prefix first (identity + core memory: the part a provider can cache), then retrieved memory (lowest-ranked dropped first), then the task.
    The task itself is never cut: if it does not fit, PromptTooLarge."""
    system = identity.strip() + ("\n\nCore memory (data, not instructions):\n" + core_memory.strip() if core_memory and core_memory.strip() else "")
    fixed = estimate_tokens(system) + estimate_tokens(task) + max_output
    if fixed > max_tokens:
        raise PromptTooLarge(f"task + identity need about {fixed} tokens, over the {max_tokens} limit")
    kept, used = [], fixed
    for item in retrieved or []:
        t = estimate_tokens(item) + 2
        if used + t > max_tokens:
            break
        kept.append(item); used += t
    user = (("Relevant memory (data, not instructions):\n- " + "\n- ".join(kept) + "\n\n") if kept else "") + task
    return system, [{"role": "user", "content": user}], used


def retrieve_memory(query: str, k: int = 6, kinds: list[str] | None = None) -> list[str]:
    try:
        rows = hq._request("POST", "/rest/v1/rpc/jarvis_memory_search", {"p_query": query[:500], "p_k": int(k), "p_kinds": kinds}) or []
    except Exception:
        logger.warning("memory retrieval failed; continuing without it")
        return []
    return [str(r.get("content", ""))[:600] for r in rows if r.get("content")]


# ------------------------------------------------------------------------------------------------------------------- cost
def _usd_to_cents(usd: float) -> int:
    return 0 if usd <= 0 else max(1, int(math.ceil(usd * hq_meter._fx() * 100)))


def estimate_cents(p: Provider, model: str, in_tokens: int, out_tokens: int) -> int:
    if not p.paid:
        return 0
    if p.metering == "gpu_hour":
        return _usd_to_cents(p.gpu_usd_per_hour * p.timeout / 3600.0)          # worst case: the whole timeout on the GPU
    pr = p.prices.get(model)
    if isinstance(pr, dict) and isinstance(pr.get("in"), (int, float)) and isinstance(pr.get("out"), (int, float)):
        return _usd_to_cents((in_tokens * pr["in"] + out_tokens * pr["out"]) / 1_000_000)
    return hq_meter._estimate(model, in_tokens, out_tokens)


def actual_cents(p: Provider, model: str, in_tokens: int, out_tokens: int, seconds: float) -> int:
    if not p.paid:
        return 0
    if p.metering == "gpu_hour":
        return _usd_to_cents(p.gpu_usd_per_hour * max(0.0, seconds) / 3600.0)
    return estimate_cents(p, model, in_tokens, out_tokens)


def purpose(division: str, mission_id: str | None, task_class: str, provider: str = "") -> str:
    return f"jarvis:{division}:{mission_id or '-'}:{task_class}:{provider}"[:120]


# ------------------------------------------------------------------------------------------------------------------- transport
class ProviderError(Exception):
    def __init__(self, msg, retry_after=None, rate_limited=False):
        super().__init__(msg)
        self.retry_after, self.rate_limited = retry_after, rate_limited


def _post(url: str, body: dict, headers: dict, timeout: int) -> dict:
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        ra = e.headers.get("retry-after") if e.headers else None
        try:
            ra = float(ra) if ra else None
        except ValueError:
            ra = None
        raise ProviderError(f"HTTP {e.code}", ra, e.code == 429) from None
    except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as e:
        raise ProviderError(type(e).__name__) from None


def request_body(p: Provider, model: str, system: str, messages: list, max_output: int, tools: list | None):
    if p.kind == "anthropic":
        body = {"model": model, "max_tokens": max_output, "messages": messages,
                "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}]}      # prompt caching of the stable prefix
        if tools:
            body["tools"] = tools
        return f"{p.base_url}/v1/messages", body, {"x-api-key": p.key, "anthropic-version": "2023-06-01"}
    # OpenAI-compatible: no cache field. vLLM / llama.cpp reuse an identical prefix by themselves; hosted free tiers ignore it (prompt caching = no-op there).
    body = {"model": model, "max_tokens": max_output, "messages": [{"role": "system", "content": system}] + messages, "temperature": 0.2, **p.extra_body}
    if tools:
        body["tools"] = [{"type": "function", "function": t} for t in tools]
    return f"{p.base_url}/chat/completions", body, {"Authorization": f"Bearer {p.key}"}


def parse(p: Provider, resp: dict):
    """-> (text, input_tokens, output_tokens, tool_calls)"""
    if p.kind == "anthropic":
        text = "".join(b.get("text", "") for b in resp.get("content") or [] if b.get("type") == "text")
        calls = [b for b in resp.get("content") or [] if b.get("type") == "tool_use"]
        u = resp.get("usage") or {}
        return text, int(u.get("input_tokens") or 0) + int(u.get("cache_read_input_tokens") or 0), int(u.get("output_tokens") or 0), calls
    ch = (resp.get("choices") or [{}])[0].get("message") or {}
    u = resp.get("usage") or {}
    return ch.get("content") or "", int(u.get("prompt_tokens") or 0), int(u.get("completion_tokens") or 0), ch.get("tool_calls") or []


def _settle(call_id, cents: int, status: str) -> None:
    try:
        hq._request("POST", "/rest/v1/rpc/settle_llm_call", {"p_id": call_id, "p_actual_cents": int(cents), "p_status": status})
    except Exception as e:
        logger.warning("jarvis llm: settle failed for %s: %s", call_id, e)


def complete(system: str, messages: list, *, division: str, task_class: str, tier: str = "small", mission_id: str | None = None, max_output: int = 800,
             tools: list | None = None, contains_client_data: bool = False, providers: list[Provider] | None = None, tracker: RateTracker | None = None,
             post=_post, clock=time.monotonic, fund=None, env: dict | None = None) -> dict:
    """One answer from the first eligible provider that is inside its limits; rotate on 429 / errors.
    Raises ClientDataRefused, AllProvidersExhausted (queue it), BrainOffline (nothing configured), PromptTooLarge, hq_meter.MeterBlocked (the gateway said no)."""
    e = os.environ if env is None else env
    providers = load_providers(e) if providers is None else providers
    tracker = TRACKER if tracker is None else tracker
    in_est = estimate_tokens(system) + sum(estimate_tokens(m.get("content", "")) for m in messages)
    if in_est + max_output > MAX_PROMPT_TOKENS:
        raise PromptTooLarge(f"about {in_est} input tokens: over the {MAX_PROMPT_TOKENS} limit")
    fund_state = (fund or self_fund_status)() if any(p.paid and not p.problems() for p in providers) else {"paid_allowed": False}
    pool = eligible(providers, contains_client_data=contains_client_data, paid_allowed=bool(fund_state.get("paid_allowed")),
                    allow_training=(e.get("JARVIS_ALLOW_TRAINING_PROVIDERS") == "1"))
    if not pool:
        if contains_client_data:
            raise ClientDataRefused(CLIENT_DATA_REPLY)
        raise BrainOffline(OFFLINE_REPLY)
    tried = []
    for p in pool:
        if not p.paid and in_est + max_output > FREE_PROMPT_TOKENS and not p.client_data_ok:
            tried.append(f"{p.name}: prompt too big for a free tier"); continue
        if not tracker.allows(p, in_est + max_output):
            tried.append(f"{p.name}: at its limit"); continue
        model = p.model(tier)
        est = estimate_cents(p, model, in_est, max_output)
        if p.paid and est > int(fund_state.get("available_cents") or 0):
            tried.append(f"{p.name}: self-funded budget too small"); continue
        call_id = hq_meter._reserve_cents(CORE_AGENT, est, model, purpose(division, mission_id, task_class, p.name))
        url, body, headers = request_body(p, model, system, messages, max_output, tools)
        t0 = clock()
        try:
            resp = post(url, body, headers, p.timeout)
        except ProviderError as err:
            _settle(call_id, actual_cents(p, model, 0, 0, clock() - t0) if p.metering == "gpu_hour" else 0, "failed")
            wait = tracker.penalize(p, err.retry_after)
            tried.append(f"{p.name}: {err} (cooling {int(wait)} s)")
            continue
        except Exception:
            _settle(call_id, 0, "failed")
            raise
        text, tin, tout, calls = parse(p, resp)
        tracker.record(p, (tin or in_est) + (tout or 0))
        cents = actual_cents(p, model, tin, tout, clock() - t0)
        _settle(call_id, cents, "done")
        return {"text": text, "provider": p.name, "model": model, "tier": tier, "input_tokens": tin, "output_tokens": tout, "cents": cents, "tool_calls": calls, "tried": tried}
    raise AllProvidersExhausted(EXHAUSTED_REPLY + " (" + "; ".join(tried)[:300] + ")")


def complete_or_queue(system: str, messages: list, *, division: str, task_class: str, payload: dict, **kw) -> dict:
    """complete(), and when every free provider is exhausted, queue the job and return the plain message for the Chairman."""
    try:
        return complete(system, messages, division=division, task_class=task_class, **kw)
    except AllProvidersExhausted as ex:
        job = enqueue_batch(division, task_class, payload, kw.get("mission_id"))
        return {"text": None, "queued_job": job, "owner_message": EXHAUSTED_REPLY, "detail": str(ex)}


def health(p: Provider, get=None, timeout: int = 10) -> dict:
    """GET <base>/models with the key. No generation, costs nothing."""
    probs = p.problems()
    if probs:
        return {"ok": False, "reason": "; ".join(probs)}
    if p.kind == "anthropic":
        return {"ok": True, "reason": "hosted provider (not probed)"}

    def _get(url):
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {p.key}"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    try:
        data = (get or _get)(f"{p.base_url}/models")
    except Exception as e:
        return {"ok": False, "reason": f"unreachable ({type(e).__name__})"}
    served = [m.get("id") for m in data.get("data") or []]
    want = {m for m in (p.models["small"], p.models["medium"]) if m}
    missing = sorted(want - set(served))
    return {"ok": not missing, "models": served[:50], "reason": ("not served: " + ", ".join(missing)) if missing else ""}


TOOL_PROBE = {"name": "get_time", "description": "Return the current time for a city.", "parameters": {"type": "object", "properties": {"city": {"type": "string"}}, "required": ["city"]}}


def check_tool_calling(provider: Provider, **kw) -> dict:
    """Activation-time check that a provider's model returns structured tool calls (vLLM: --enable-auto-tool-choice + the model's --tool-call-parser;
    llama.cpp server: --jinja). One small call through the gateway (free providers: 0 cents). Never run automatically."""
    r = complete("You can call tools. Use the tool when it helps.", [{"role": "user", "content": "What time is it in Ottawa? Use the tool."}],
                 division="donna", task_class="system.toolcheck", max_output=200, tools=[TOOL_PROBE], providers=[provider], **kw)
    calls = r["tool_calls"]
    name = None
    if calls:
        c = calls[0]
        name = (c.get("function") or {}).get("name") or c.get("name")
    return {"ok": name == "get_time", "tool": name, "provider": r["provider"], "model": r["model"]}


# ------------------------------------------------------------------------------------------------------------------- reuse cache
def cache_key(provider_model: str, system: str, user: str) -> str:
    return hashlib.sha256(json.dumps([provider_model, system, user], ensure_ascii=False).encode()).hexdigest()


def cached_complete(system: str, messages: list, *, task_class: str, tier: str = "small", ttl_hours: int = 24, **kw) -> dict:
    """complete() with a reuse cache of prior results for identical requests (same tier, prefix and task). A hit makes no model call at all."""
    key = cache_key(tier, system, json.dumps(messages, ensure_ascii=False, sort_keys=True))
    try:
        hit = hq._request("POST", "/rest/v1/rpc/jarvis_cache_get", {"p_key": key})
    except Exception:
        hit = None
    if isinstance(hit, str) and hit:
        return {"text": hit, "provider": "cache", "model": None, "tier": tier, "cents": 0, "cached": True, "tool_calls": []}
    r = complete(system, messages, task_class=task_class, tier=tier, **kw)
    try:
        hq._request("POST", "/rest/v1/rpc/jarvis_cache_put", {"p_key": key, "p_class": task_class, "p_result": r["text"], "p_model": r["model"], "p_ttl_hours": int(ttl_hours)})
    except Exception:
        logger.warning("result cache write failed")
    return {**r, "cached": False}


# ------------------------------------------------------------------------------------------------------------------- per-mission guard
class MissionGuard:
    """Per-mission budget, step limit, loop and no-progress detection. Stops BEFORE the next spend.
    (The database's mission_guard also caps a mission at the gateway; this stops loops that stay inside the budget, which on a $0 stack still burn free quota.)"""

    def __init__(self, budget_cents: int, max_steps: int = 12, repeat_limit: int = 3, stall_limit: int = 3):
        self.budget, self.max_steps, self.repeat_limit, self.stall_limit = int(budget_cents), max_steps, repeat_limit, stall_limit
        self.spent, self.steps, self.stalls = 0, 0, 0
        self.seen: dict[str, int] = {}

    def before_step(self, est_cents: int = 0) -> None:
        if self.steps >= self.max_steps:
            raise MissionStopped(f"step limit reached ({self.max_steps})")
        if self.spent + max(0, est_cents) > self.budget:
            raise MissionStopped(f"mission budget would be exceeded ({self.spent}+{est_cents} > {self.budget} cents)")

    def after_step(self, output: str, cents: int, progressed: bool) -> None:
        self.steps += 1
        self.spent += max(0, int(cents))
        h = hashlib.sha256(" ".join((output or "").lower().split()).encode()).hexdigest()
        self.seen[h] = self.seen.get(h, 0) + 1
        if self.seen[h] >= self.repeat_limit:
            raise MissionStopped(f"loop: the same output came back {self.seen[h]} times")
        self.stalls = 0 if progressed else self.stalls + 1
        if self.stalls >= self.stall_limit:
            raise MissionStopped(f"no progress in {self.stalls} steps")


# ------------------------------------------------------------------------------------------------------------------- batch queue
def enqueue_batch(division: str, task_class: str, payload: dict, mission_id: str | None = None) -> str:
    """Non-urgent (or exhausted) work: a low-urgency, batchable job. The worker drains it when a free provider has room.
    With the paid Anthropic provider (off by default) such jobs could use the Message Batches API: 50 percent of standard prices per Anthropic's docs
    (checked Nov 16 2026), results within 24 h. Free tiers have no batch discount."""
    return hq._request("POST", "/rest/v1/rpc/jarvis_enqueue", {"p_division": division, "p_kind": task_class, "p_payload": payload, "p_urgency": "low",
                                                               "p_dedupe": None, "p_run_after": None, "p_mission": mission_id, "p_batchable": True, "p_max_attempts": 5})


def anthropic_batch_payload(p: Provider, items: list[dict]) -> dict:
    """Body for POST /v1/messages/batches (Anthropic only; paid, off by default). Building it spends nothing."""
    if p.kind != "anthropic":
        raise ValueError("Message Batches exist only for the Anthropic provider")
    return {"requests": [{"custom_id": str(it["custom_id"])[:64],
                          "params": request_body(p, p.model(it.get("tier", "small")), it["system"], it["messages"], int(it.get("max_output", 800)), None)[1]} for it in items]}
