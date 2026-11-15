# Agent Swarm integration (ISOLATED DEVELOPMENT ONLY)
Nothing here runs in production. No real LLM worker has been run. See SWARM_POC_REPORT.md and hardening/SWARM_PILOT_GATE.md.
- poc/: HQ adapter prototype (swarm_adapter.py) that never creates a Swarm task when the HQ executor gate refuses or dry_run is on.
- hardening/: hardened compose, default-deny worker gate (config/worker_gate.py), non-root worker image + entrypoint, controls verifier (verify_swarm_controls.py), evidence.
Pilot requires: Docker host, pinned image digests, dedicated hard-capped model key, isolation tests I1-I17, executor registry release (build/executor-sweep) — all owner/infra gated.
