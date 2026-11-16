"""Tests for scripts/org_contract.py and the organization contract ops/org/divisions.json. No database.
Each test names the property it proves (docs/org/ORG_ARCHITECTURE.md, security self-review)."""
import copy
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import org_contract as oc  # noqa: E402


class Base(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.schema = oc.load(oc.SCHEMA)
        cls.good = oc.load(oc.CONTRACT)

    def doc(self):
        return copy.deepcopy(self.good)

    def div(self, doc, slug="donna"):
        return next(d for d in doc["divisions"] if d["id"] == slug)

    def assertFinding(self, doc, needle):
        errs = oc.validate(doc, self.schema)
        self.assertTrue(any(needle in e for e in errs), f"expected a finding containing {needle!r}, got {errs}")


class ShippedContract(Base):
    def test_shipped_contract_is_valid(self):
        self.assertEqual(oc.validate(self.good, self.schema), [])

    def test_everything_is_dormant_and_zero(self):
        for d in self.good["divisions"]:
            self.assertEqual(d["status"], "dormant")
            self.assertEqual((d["budget"]["daily_envelope_cents"], d["budget"]["monthly_envelope_cents"], d["budget"]["proposed_daily_cents"]), (0, 0, 0))
            self.assertEqual(d["delegated_permissions"]["default"], "deny")
            self.assertTrue(all(a["status"] == "dormant" for a in d["delegated_permissions"]["allow"]))
            self.assertEqual(d["manager"]["agent_status"], "not_created")
            self.assertTrue(all(r["agent_status"] == "not_created" for r in d["team"]))
            self.assertTrue(all(t["status"] == "dormant" and t["max_budget_cents"] == 0 for t in d["mission_templates"]))

    def test_inferred_divisions_are_flagged_and_unapproved(self):
        # the repo does not define eight divisions: the inferred ones must say so, and no charter may claim owner approval
        self.assertEqual(len(self.good["divisions"]), 8)
        self.assertEqual({d["id"] for d in self.good["divisions"] if d["inferred"]}, {"research", "music", "soccer"})
        self.assertTrue(all(d["charter"]["owner_approved"] is False and d["charter"]["authored_by"] == "operator_draft" for d in self.good["divisions"]))

    def test_only_ffm_touches_client_workspaces(self):
        for d in self.good["divisions"]:
            scopes = {a["scope"] for a in d["delegated_permissions"]["allow"]}
            if d["id"] == "ffm":
                self.assertEqual(d["isolation"]["client_workspace_access"], "own_workspaces_aggregate_only")
            else:
                self.assertEqual(d["isolation"]["client_workspace_access"], "none")
                self.assertNotIn("own_workspaces", scopes)

    def test_cap_matches_the_owner_stated_cap(self):
        self.assertEqual(self.good["global"]["ai_daily_cap_cents"], 330)


class NoActivation(Base):
    def test_active_division_is_refused(self):
        d = self.doc(); self.div(d)["status"] = "active"
        self.assertFinding(d, "S4 division donna")

    def test_staged_division_is_refused_in_the_contract(self):
        d = self.doc(); self.div(d)["status"] = "staged"
        self.assertFinding(d, "S4 division donna")

    def test_granted_permission_is_refused(self):
        d = self.doc(); self.div(d)["delegated_permissions"]["allow"][0]["status"] = "granted"
        self.assertFinding(d, "S9 division donna")

    def test_active_mission_template_is_refused(self):
        d = self.doc(); self.div(d)["mission_templates"][0]["status"] = "active"
        self.assertFinding(d, "S4 division donna: mission template")

    def test_created_agent_is_refused_by_schema(self):
        d = self.doc(); self.div(d)["manager"]["agent_status"] = "active"
        self.assertFinding(d, "manager.agent_status")
        d = self.doc(); self.div(d)["team"][0]["agent_status"] = "paused"
        self.assertFinding(d, "agent_status")

    def test_default_allow_is_refused_by_schema(self):
        d = self.doc(); self.div(d)["delegated_permissions"]["default"] = "allow"
        self.assertFinding(d, "delegated_permissions.default")


class Budget(Base):
    def test_nonzero_envelope_is_refused(self):
        for key in ("daily_envelope_cents", "monthly_envelope_cents"):
            d = self.doc(); self.div(d)["budget"][key] = 1
            self.assertFinding(d, "S5 division donna")

    def test_mission_template_budget_is_refused(self):
        d = self.doc(); self.div(d)["mission_templates"][0]["max_budget_cents"] = 5
        self.assertFinding(d, "S5 division donna: mission template")

    def test_proposal_above_global_cap_is_refused(self):
        d = self.doc(); self.div(d)["budget"]["proposed_daily_cents"] = 331
        self.assertFinding(d, "S6 division donna")

    def test_proposals_summing_above_global_cap_are_refused(self):
        d = self.doc()
        self.div(d, "donna")["budget"]["proposed_daily_cents"] = 200
        self.div(d, "ffm")["budget"]["proposed_daily_cents"] = 131
        self.assertFinding(d, "S6 proposed daily envelopes add up to 331")
        self.div(d, "ffm")["budget"]["proposed_daily_cents"] = 130   # exactly the cap is fine
        self.assertEqual(oc.validate(d, self.schema), [])

    def test_spend_must_go_through_the_gateway(self):
        d = self.doc(); self.div(d)["budget"]["spend_path"] = "direct"
        self.assertFinding(d, "budget.spend_path")

    def test_negative_budget_is_refused_by_schema(self):
        d = self.doc(); self.div(d)["budget"]["proposed_daily_cents"] = -1
        self.assertFinding(d, "below 0")


class NoSelfEscalation(Base):
    def test_every_protected_capability_is_refused(self):
        for cap in ("grant.create", "delegation.grant", "division.activate", "budget.set", "permission.change", "spend_cap.change", "kill_switch.set",
                    "executor.register", "payment.send", "bank.read", "backup.run", "deploy.release", "migration.apply", "owner.contact",
                    "privacy.change", "consent.record", "outbox.send", "secret.read", "agent.create", "agent.activate"):
            d = self.doc(); self.div(d)["delegated_permissions"]["allow"].append({"capability": cap, "scope": "own_division", "status": "dormant"})
            self.assertFinding(d, f"S8 division donna: capability {cap}")

    def test_protected_capability_cannot_be_added_to_the_catalog(self):
        d = self.doc(); d["global"]["capability_catalog"].append({"id": "division.activate", "tier": "green", "description": "activate a division"})
        self.assertFinding(d, "S2 catalog capability division.activate")

    def test_contract_cannot_shrink_the_never_delegable_list(self):
        d = self.doc(); d["global"]["never_delegable_prefixes"] = ["payment."]
        self.assertFinding(d, "S1 global.never_delegable_prefixes drops built-in entries")
        # and even with the list emptied, the built-in list still refuses the capability
        self.div(d)["delegated_permissions"]["allow"].append({"capability": "division.activate", "scope": "own_division", "status": "dormant"})
        self.assertFinding(d, "S8 division donna: capability division.activate")

    def test_unknown_capability_is_refused(self):
        d = self.doc(); self.div(d)["delegated_permissions"]["allow"].append({"capability": "files.delete", "scope": "own_division", "status": "dormant"})
        self.assertFinding(d, "S7 division donna: capability files.delete is not in the capability catalog")

    def test_cross_division_scope_is_refused_by_schema(self):
        d = self.doc(); self.div(d)["delegated_permissions"]["allow"][0]["scope"] = "all_divisions"
        self.assertFinding(d, "scope")

    def test_reading_other_divisions_is_refused(self):
        d = self.doc(); self.div(d)["isolation"]["reads_other_divisions"] = True
        self.assertFinding(d, "S10 division donna: a division may not read other divisions")

    def test_workspace_scope_needs_declared_isolation(self):
        d = self.doc(); self.div(d)["delegated_permissions"]["allow"][0]["scope"] = "own_workspaces"
        self.assertFinding(d, "S10 division donna")

    def test_mission_template_cannot_need_more_than_the_allow_list(self):
        d = self.doc(); self.div(d, "day-job-sales")["mission_templates"][0]["required_capabilities"].append("research.fetch")
        self.assertFinding(d, "S8 division day-job-sales: mission template")

    def test_manager_cannot_contact_owner(self):
        d = self.doc(); self.div(d)["manager"]["can_contact_owner"] = True
        self.assertFinding(d, "S11 division donna")

    def test_manager_must_report_to_jarvis(self):
        d = self.doc(); self.div(d)["manager"]["reports_to"] = "owner"
        self.assertFinding(d, "manager.reports_to")


class Hygiene(Base):
    def test_personal_data_in_free_text_is_refused(self):
        d = self.doc(); self.div(d)["charter"]["text"] += " Contact jane.doe@example.com for details."
        self.assertFinding(d, "S12")
        d = self.doc(); self.div(d)["responsibilities"].append("Call 613-555-0142 every morning")
        self.assertFinding(d, "S12")

    def test_duplicate_ids_are_refused(self):
        d = self.doc(); d["divisions"].append(copy.deepcopy(self.div(d)))
        self.assertFinding(d, "S3 duplicate division id")
        d = self.doc(); self.div(d)["kpis"].append(copy.deepcopy(self.div(d)["kpis"][0]))
        self.assertFinding(d, "S3 division donna: duplicate KPI id")

    def test_unexpected_keys_are_refused(self):
        d = self.doc(); self.div(d)["api_key"] = "x"
        self.assertFinding(d, "unexpected key 'api_key'")
        d = self.doc(); d["divisions"][0]["budget"]["override"] = True
        self.assertFinding(d, "unexpected key 'override'")

    def test_missing_required_key_is_refused(self):
        d = self.doc(); del self.div(d)["delegated_permissions"]
        self.assertFinding(d, "missing 'delegated_permissions'")

    def test_bool_is_not_an_integer(self):
        d = self.doc(); self.div(d)["budget"]["daily_envelope_cents"] = False
        self.assertFinding(d, "expected integer")


class Seed(Base):
    def test_migration_seed_matches_the_contract(self):
        with open(oc.MIGRATION, encoding="utf-8") as f:
            self.assertEqual(oc.migration_seed(f.read()), oc.emit_seed(self.good))

    def test_seed_has_no_status_or_money_columns(self):
        # the seed relies on the table defaults (dormant, 0): it must not be able to carry an active status or an amount
        seed = oc.emit_seed(self.good)
        for word in ("status", "cents", "active", "granted", "staged"):
            self.assertNotIn(word, seed)
        self.assertEqual(seed.count("'own_workspaces'"), len(self.div(self.good, "ffm")["delegated_permissions"]["allow"]))

    def test_seed_quotes_sql(self):
        d = self.doc(); self.div(d)["name"] = "O'Brien"
        self.assertIn("'O''Brien'", oc.emit_seed(d))

    def test_main_exit_codes(self):
        self.assertEqual(oc.main(["--check-migration"]), 0)


if __name__ == "__main__":
    unittest.main()
