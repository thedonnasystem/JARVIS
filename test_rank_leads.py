import csv, os, subprocess, sys, tempfile, unittest
from datetime import date, timedelta
sys.path.insert(0, "scripts")
import rank_leads as R

T = date(2026, 11, 12)
COLS = {"name": "Name", "phone": "Phone", "status": "Notes", "last": "Last Contact", "usage": "Annual kWh"}


class Tst(unittest.TestCase):
    def s(self, **kw):
        row = {"Name": "A", "Phone": "613-555-0101", "Notes": "", "Last Contact": "", "Annual kWh": ""}; row.update(kw)
        return R.score(row, COLS, T)

    def test_exclusions(self):
        self.assertIsNone(self.s(Notes="Do Not Call"))
        self.assertIsNone(self.s(Notes="not interested"))
        self.assertIsNone(self.s(Phone="555"))

    def test_warm_beats_cold_and_window_matters(self):
        warm = self.s(Notes="said call back next week")[0]; cold = self.s()[0]
        self.assertGreater(warm, cold)
        recent = self.s(**{"Last Contact": (T - timedelta(days=3)).isoformat()})[0]
        window = self.s(**{"Last Contact": (T - timedelta(days=40)).isoformat()})[0]
        self.assertGreater(window, recent)

    def test_usage_bump_and_reasons(self):
        hi = self.s(**{"Annual kWh": "15,000"}); self.assertGreater(hi[0], self.s()[0]); self.assertTrue(any("usage" in w for w in hi[1]))

    def test_cli_end_to_end(self):
        with tempfile.TemporaryDirectory() as d:
            p, o = os.path.join(d, "in.csv"), os.path.join(d, "out.csv")
            with open(p, "w", newline="") as f:
                w = csv.writer(f); w.writerow(["Name", "Cell Phone", "Disposition", "Last Contact Date"])
                w.writerow(["Hot", "6135550101", "interested, call back", "2026-10-01"]); w.writerow(["DNC", "6135550102", "DNC", ""]); w.writerow(["Cold", "6135550103", "", ""])
            r = subprocess.run([sys.executable, "scripts/rank_leads.py", p, "--out", o], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr); rows = list(csv.reader(open(o)))
            self.assertEqual(rows[1][3], "Hot"); self.assertEqual(len(rows), 3); self.assertIn("Excluded 1", r.stdout)


if __name__ == "__main__":
    unittest.main()
