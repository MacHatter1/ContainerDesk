import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("smoke_test.sh")
MOCK_CLI = r'''#!/usr/bin/python3
import json, os, signal, sys
from pathlib import Path

args = sys.argv[1:]
cleanup = args[0] in ("stop", "delete") or (len(args) > 1 and args[1] == "delete")
record = {"args": args, "cleanup": cleanup}
if args[:2] == ["network", "create"]:
    name = args[-1][:-4]
    console = Path(os.environ["CONTAINERDESK_SMOKE_MOCK_OUTPUT"]).read_text()
    record["announced"] = all(value in console for value in (
        "container=" + name, "network=" + name + "-net", "volume=" + name + "-vol",
        "image=" + name + ":build", "image_tag=" + name + ":tagged",
    ))
with open(os.environ["CONTAINERDESK_SMOKE_MOCK_LOG"], "a") as log:
    log.write(json.dumps(record) + "\n")
if cleanup and os.environ["CONTAINERDESK_SMOKE_MOCK_CLEANUP_FAILURE"] == "1":
    print("simulated cleanup failure", file=sys.stderr)
    sys.exit(9)
if args[:2] == ["builder", "status"]:
    print('[{"id":"buildkit","status":{"state":"running"}}]')
elif args[0] == "inspect":
    requested_signal = os.environ["CONTAINERDESK_SMOKE_MOCK_SIGNAL"]
    if requested_signal:
        os.kill(os.getppid(), int(requested_signal))
    elif os.environ["CONTAINERDESK_SMOKE_MOCK_OPERATION_FAILURE"] == "1":
        print("simulated inspection failure", file=sys.stderr)
        sys.exit(8)
elif args[0] == "exec" and args[2] == "cat":
    print("ContainerDesk smoke " + args[1].rsplit("-", 1)[-1])
'''


@unittest.skipUnless(sys.platform == "darwin", "The smoke script uses macOS tools")
class SmokeCleanupTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory(prefix="containerdesk-smoke-test-")
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.mock = self.root / "container-mock"
        self.mock.write_text(MOCK_CLI)
        self.mock.chmod(0o700)

    def run_case(self, *, operation_failure=False, cleanup_failure=False,
                 requested_signal=None, keep=False):
        calls_path = self.root / "calls.jsonl"
        output_path = self.root / "console.log"
        calls_path.write_text("")
        env = dict(os.environ, CONTAINER_CLI=str(self.mock),
                   CONTAINERDESK_SMOKE_MOCK_LOG=str(calls_path),
                   CONTAINERDESK_SMOKE_MOCK_OUTPUT=str(output_path),
                   CONTAINERDESK_SMOKE_MOCK_OPERATION_FAILURE=str(int(operation_failure)),
                   CONTAINERDESK_SMOKE_MOCK_CLEANUP_FAILURE=str(int(cleanup_failure)),
                   CONTAINERDESK_SMOKE_MOCK_SIGNAL=str(int(requested_signal)) if requested_signal else "")
        command = ["bash", str(SCRIPT)] + (["--keep-for-ui"] if keep else [])
        with output_path.open("w") as console:
            result = subprocess.run(command, env=env, stdout=console,
                                    stderr=subprocess.STDOUT, timeout=20)
        output = output_path.read_text()
        for line in output.splitlines():
            key, separator, value = line.partition("=")
            if separator and key == "host_copy":
                path = Path(value)
                self.assertEqual(path.parent, Path("/private/tmp"))
                self.assertTrue(path.name.startswith("containerdesk-copy."))
                self.addCleanup(path.unlink, missing_ok=True)
            elif separator and key == "image_archive":
                path = Path(value).parent
                self.assertEqual(path.parent, Path("/private/tmp"))
                self.assertTrue(path.name.startswith("containerdesk-smoke."))
                self.addCleanup(shutil.rmtree, path, ignore_errors=True)
        calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
        creation = next(call for call in calls if call["args"][:2] == ["network", "create"])
        self.assertTrue(creation["announced"], "Resource names must be logged before creation")
        return result.returncode, output, [call for call in calls if call["cleanup"]]

    def test_success_requires_completed_cleanup(self):
        status, output, cleanup = self.run_case()
        self.assertEqual(status, 0)
        self.assertEqual(len(cleanup), 6)
        self.assertIn("Smoke checks and cleanup passed.", output)

    def test_cleanup_failure_fails_the_run_and_attempts_every_resource(self):
        status, output, cleanup = self.run_case(cleanup_failure=True)
        self.assertEqual(status, 1)
        self.assertEqual(len(cleanup), 6)
        self.assertEqual(output.count("Smoke cleanup failed:"), 6)
        self.assertIn("Smoke cleanup incomplete", output)
        self.assertNotIn("Smoke checks and cleanup passed.", output)

    def test_operation_failure_preserves_its_exit_status(self):
        status, output, cleanup = self.run_case(operation_failure=True)
        self.assertEqual(status, 8)
        self.assertEqual(len(cleanup), 4)
        self.assertNotIn("Smoke checks and cleanup passed.", output)

    def test_operation_failure_survives_cleanup_failure(self):
        status, output, cleanup = self.run_case(operation_failure=True, cleanup_failure=True)
        self.assertEqual(status, 8)
        self.assertEqual(len(cleanup), 4)
        self.assertEqual(output.count("Smoke cleanup failed:"), 4)

    def test_keep_for_ui_does_not_delete_resources(self):
        status, output, cleanup = self.run_case(keep=True)
        self.assertEqual(status, 0)
        self.assertEqual(cleanup, [])
        self.assertIn("Smoke resources retained for UI review", output)
        self.assertNotIn("Smoke checks and cleanup passed.", output)

    def test_signals_cleanup_once_and_keep_signal_status(self):
        for requested_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=requested_signal):
                status, output, cleanup = self.run_case(requested_signal=requested_signal)
                self.assertEqual(status, 128 + requested_signal)
                self.assertEqual(len(cleanup), 4)
                self.assertNotIn("Smoke checks and cleanup passed.", output)


if __name__ == "__main__":
    unittest.main()
