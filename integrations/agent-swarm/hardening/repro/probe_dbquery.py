import json, sys, os
from lib import *
from probe_mcp_helpers import mcp_call
for label, extra in (("WITHOUT SECRETS_ENCRYPTION_KEY", {}), ("WITH SECRETS_ENCRYPTION_KEY", {"SECRETS_ENCRYPTION_KEY": os.environ['TK']})):
    print("=====", label)
    with Server(extra_env=extra) as S:
        b, K = S.base, S.key
        s, tk = call(b, "POST", "/api/agents/pilot-worker-1/token", K, {"name": "pilot-worker"}); WT = tk["plaintext"]
        RT = {"X-Agent-ID": "pilot-worker-1"}
        call(b, "POST", "/api/agents", WT, {"name": "pilot-worker", "isLead": False, "role": "coder", "capabilities": ["code"], "maxTasks": 1, "runtimeInstanceId": "rt1"}, RT)
        s, r = call(b, "PUT", "/api/config", K, {"scope": "global", "key": "FAKE_GLOBAL_SECRET", "value": "THROWAWAY-GLOBAL-SECRET-VALUE", "isSecret": True}); print("seed secret", s)
        s, r = call(b, "POST", "/api/db-query", WT, {"sql": "SELECT key, value, isSecret FROM swarm_config WHERE isSecret=1"}, RT)
        print("REST db-query swarm_config secrets:", s, json.dumps(r)[:300])
        s, r = call(b, "POST", "/api/db-query", WT, {"sql": "SELECT tokenHash FROM session_tokens"}, RT)
        print("REST db-query session_tokens:", s, json.dumps(r)[:200])
        s, r = call(b, "POST", "/api/db-query", WT, {"sql": "SELECT id,name,isLead,status FROM agents"}, RT); print("REST db-query agents:", s, json.dumps(r)[:150])
        s, r = call(b, "POST", "/api/db-query", WT, {"sql": "SELECT id,task,status FROM agent_tasks LIMIT 3"}, RT); print("REST db-query tasks:", s, json.dumps(r)[:150])
        s, r = call(b, "POST", "/api/db-query", WT, {"sql": "SELECT name FROM sqlite_master WHERE name LIKE '%key%' OR name LIKE '%token%'"}, RT); print("REST db-query schema:", s, json.dumps(r)[:300])
