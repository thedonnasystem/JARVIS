import asyncio
import re
import unittest
import urllib.error
from unittest import mock

import hq_executor as EX


def http(code):
    return urllib.error.HTTPError("http://x", code, "err", {}, None)


class ExpireStale(unittest.TestCase):
    def setUp(self):
        EX._warned_missing = False

    def test_off_when_hq_disabled_makes_no_call(self):
        with mock.patch.object(EX.hq, "hq_enabled", return_value=False), mock.patch.object(EX, "_rpc") as r:
            self.assertIsNone(EX.expire_stale_sync())
        r.assert_not_called()

    def test_calls_rpc_with_minutes_and_returns_count(self):
        with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", return_value=2) as r:
            self.assertEqual(EX.expire_stale_sync(60), 2)
        r.assert_called_once_with("executor_expire_stale", {"p_minutes": 60})

    def test_missing_function_is_quiet_noop_and_logs_once(self):
        with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", side_effect=http(404)), \
                self.assertLogs(EX.logger, "INFO") as lg:
            self.assertIsNone(EX.expire_stale_sync()); self.assertIsNone(EX.expire_stale_sync())
        self.assertEqual(len(lg.records), 1)

    def test_other_errors_never_raise(self):
        for exc in (http(500), RuntimeError("boom"), TimeoutError()):
            with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", side_effect=exc), \
                    self.assertLogs(EX.logger):
                self.assertIsNone(EX.expire_stale_sync())

    def test_async_job_runs_sync_in_thread(self):
        with mock.patch.object(EX, "expire_stale_sync", return_value=0) as s:
            asyncio.run(EX.expire_stale_job(None))
        s.assert_called_once_with()

    def test_bot_registers_job_every_10_minutes_independent_of_engine_tick(self):
        src = open("bot.py").read()
        self.assertIn("import hq_executor", src)
        m = re.search(r"run_repeating\(hq_executor\.expire_stale_job, interval=hq_executor\.EXPIRE_EVERY_SECONDS", src)
        self.assertTrue(m, "bot.py does not schedule hq_executor.expire_stale_job")
        self.assertEqual(EX.EXPIRE_EVERY_SECONDS, 600)
        self.assertNotIn("expire_stale", open("hq_engine.py").read())


class SweepBehaviour(unittest.TestCase):
    def setUp(self):
        EX._warned_missing = False

    def test_job_survives_errors_and_keeps_working_next_run(self):
        seq = iter([RuntimeError("down"), http(500), 3, 0])
        def rpc(name, args):
            v = next(seq)
            if isinstance(v, Exception): raise v
            return v
        with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", rpc), self.assertLogs(EX.logger):
            for _ in range(4):
                asyncio.run(EX.expire_stale_job(None))   # must never raise

    def test_repeated_runs_are_idempotent_by_contract(self):
        with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", side_effect=[2, 0]) as r, self.assertLogs(EX.logger):
            self.assertEqual(EX.expire_stale_sync(), 2); self.assertEqual(EX.expire_stale_sync(), 0)
        self.assertEqual(r.call_count, 2)   # the settle-in-full and the no-double-charge guarantee live in executor_expire_stale (sqltests/executor_sweep_check.sql S6-S12)

    def test_sweep_does_not_depend_on_kill_switch_or_pause(self):
        # it goes straight to the executor_expire_stale RPC; it never reads system_state / engine state, so it still runs when hq_engine.tick returns early
        names = set(EX.expire_stale_sync.__code__.co_names) | set(EX.expire_stale_job.__code__.co_names)   # code only, not docstrings
        self.assertFalse({n for n in names if any(w in n.lower() for w in ("kill", "pause", "engine", "state", "credit"))}, names)
        self.assertNotIn("import hq_engine", open("hq_executor.py").read())

    def test_missing_function_400_is_quiet_noop(self):
        with mock.patch.object(EX.hq, "hq_enabled", return_value=True), mock.patch.object(EX, "_rpc", side_effect=http(400)), self.assertLogs(EX.logger, "INFO") as lg:
            self.assertIsNone(EX.expire_stale_sync())
        self.assertTrue(all(r.levelname == "INFO" for r in lg.records))


if __name__ == "__main__":
    unittest.main()
