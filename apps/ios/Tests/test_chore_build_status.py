import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from chore_build_status import BuildStatus, collect


def task(number, target, state, stage=None):
    return {
        "id": f"{number:032x}",
        "application": {"project": "C:/private/Project.xcodeproj", "target": target},
        "state": state,
        "current_stage": stage,
        "created_utc": f"2026-11-05T20:00:{number:02}+08:00",
        "logs": {"stdout": "C:/private/workflow.log"},
    }


class ChoreBuildStatusTests(unittest.TestCase):
    def test_status_queries_only_on_request_and_reuses_recent_result(self):
        clock = 10.0
        config = {"xkode": "xkode", "project": "apps/ios/Hako.xcodeproj"}
        with (patch("chore_build_status.time.monotonic", side_effect=lambda: clock),
              patch("chore_build_status.read_json", return_value=config),
              patch("chore_build_status.collect", side_effect=[{"active": []}, {"active": ["new"]}]) as read):
            status = BuildStatus(Path("config.json"))
            read.assert_not_called()
            self.assertEqual(json.loads(status.snapshot()), {"active": []})
            clock = 11.0
            self.assertEqual(json.loads(status.snapshot()), {"active": []})
            clock = 13.0
            self.assertEqual(read.call_count, 1)
            self.assertEqual(json.loads(status.snapshot()), {"active": ["new"]})
            self.assertEqual(read.call_count, 2)

    def test_all_projects_active_and_latest_three_completed(self):
        tasks = [task(n, "Hako", "succeeded") for n in range(4)]
        tasks += [task(4, "Other App", "running", "sign"), task(5, "Hako", "queued")]
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "apps/ios/Hako.xcodeproj"
            with patch("chore_build_status.subprocess.run",
                       return_value=subprocess.CompletedProcess([], 0, json.dumps({"tasks": tasks}))):
                snapshot = collect(Path("xkode"), project)
        self.assertEqual([row["target"] for row in snapshot["active"]], ["Hako", "Other App"])
        self.assertEqual(snapshot["active"][1]["stages"], {"sign": "running"})
        self.assertEqual([row["id"] for row in snapshot["history"]], [f"{n:032x}" for n in (3, 2, 1)])
        self.assertNotIn("C:/private", json.dumps(snapshot))

    def test_publication_requires_verified_delivery(self):
        completed = task(1, "Hako", "succeeded")
        completed["result"] = {"ipa": "C:/private/Hako.ipa"}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            build = root / "build/ios-test"
            build.mkdir(parents=True)
            delivery = build / "delivery-status.json"
            project = root / "apps/ios/Hako.xcodeproj"
            with patch("chore_build_status.subprocess.run",
                       return_value=subprocess.CompletedProcess([], 0, json.dumps({"tasks": [completed]}))):
                self.assertEqual(collect(Path("xkode"), project)["history"][0]["stages"]["publish"], "pending")
                delivery.write_text(json.dumps({"jobId": completed["id"], "publicVerified": True}))
                self.assertEqual(collect(Path("xkode"), project)["history"][0]["stages"]["publish"], "succeeded")

    def test_details_expose_stage_timings_without_local_paths(self):
        failed = task(1, "Hako", "failed")
        failed["stages"] = {
            "build": {"state": "succeeded", "elapsed_seconds": 12.5},
            "sign": {"state": "failed", "started_utc": "2026-11-05T12:00:00Z",
                     "finished_utc": "2026-11-05T12:00:02Z"},
        }
        failed["error"] = {"stage": "sign", "message": "C:/private/signing.log",
                           "partial_result": {"elapsed_seconds": 16.5}}
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "apps/ios/Hako.xcodeproj"
            with patch("chore_build_status.subprocess.run",
                       return_value=subprocess.CompletedProcess([], 0, json.dumps({"tasks": [failed]}))):
                row = collect(Path("xkode"), project)["history"][0]
        self.assertEqual(row["project"], "Project")
        self.assertEqual(row["failedStage"], "sign")
        self.assertEqual(row["elapsedSeconds"], 16.5)
        self.assertEqual(row["stageDurations"], {"build": 12.5, "sign": 2})
        self.assertNotIn("C:/private", json.dumps(row))


if __name__ == "__main__":
    unittest.main()
