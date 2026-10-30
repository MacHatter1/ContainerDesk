import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().with_name("plugin_smoke_test.sh")
MOCK_CLI = r'''#!/usr/bin/python3
import json, os, signal, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ["PLUGIN_TEST_CALLS"], "a") as stream:
    stream.write(json.dumps(args) + "\n")
cleanup = (args[:2] == ["compose", "down"] and "--keep-networks" not in args) or args[:2] == ["k8s", "delete"]
if cleanup and os.environ["PLUGIN_TEST_CLEANUP_FAIL"] == "1":
    print("fixture-private-output", file=sys.stderr)
    sys.exit(9)
if args[:2] == ["k8s", "create"]:
    if os.environ["PLUGIN_TEST_SIGNAL"]:
        os.kill(os.getppid(), int(os.environ["PLUGIN_TEST_SIGNAL"]))
    if os.environ["PLUGIN_TEST_OPERATION_FAIL"] == "1":
        sys.exit(8)
if args[:2] == ["k8s", "list"]:
    calls = [json.loads(line) for line in Path(os.environ["PLUGIN_TEST_CALLS"]).read_text().splitlines()]
    create = next(call for call in calls if call[:2] == ["k8s", "create"])
    print(create[create.index("--name") + 1])
if args[:2] == ["k8s", "write-config"]:
    Path(args[args.index("--kubeconfig") + 1]).write_text("fixture-config")
'''


@unittest.skipUnless(sys.platform == "darwin", "The smoke script uses macOS tools")
class PluginSmokeCleanupTests(unittest.TestCase):
    def run_case(self, *, mode=None, cleanup_failure=False, operation_failure=False, requested_signal=None):
        with tempfile.TemporaryDirectory(prefix="plugin-smoke-test-") as directory:
            root = Path(directory)
            mock = root / "container"
            mock.write_text(MOCK_CLI)
            mock.chmod(0o700)
            calls_path = root / "calls.jsonl"
            env = dict(os.environ, CONTAINER_CLI=str(mock), PLUGIN_TEST_CALLS=str(calls_path),
                       PLUGIN_TEST_CLEANUP_FAIL=str(int(cleanup_failure)),
                       PLUGIN_TEST_OPERATION_FAIL=str(int(operation_failure)),
                       PLUGIN_TEST_SIGNAL=str(int(requested_signal)) if requested_signal else "")
            result = subprocess.run(["bash", str(SCRIPT)] + ([mode] if mode else []), env=env,
                                    capture_output=True, text=True, timeout=20)
            calls = [json.loads(line) for line in calls_path.read_text().splitlines()]
            return result.returncode, result.stdout + result.stderr, calls

    def test_compose_cleanup_failure_cannot_report_success(self):
        status, output, calls = self.run_case(mode="--compose-only", cleanup_failure=True)
        self.assertEqual(status, 1)
        self.assertIn("Compose cleanup: failed", output)
        self.assertIn("Cleanup incomplete: inspect Compose project containerdesk-plugin-smoke-", output)
        self.assertNotIn("Compose smoke passed", output)
        self.assertNotIn("fixture-private-output", output)
        self.assertEqual(calls[-1][:2], ["compose", "down"])
        self.assertNotIn("--keep-networks", calls[-1])

    def test_cleanup_failure_preserves_operation_failure_and_attempts_both_resources(self):
        status, output, calls = self.run_case(operation_failure=True, cleanup_failure=True)
        self.assertEqual(status, 8)
        self.assertIn("Compose cleanup: failed", output)
        self.assertIn("Kubernetes cleanup: failed", output)
        self.assertNotIn("smoke passed", output)
        self.assertEqual(calls[-2][:2], ["compose", "down"])
        self.assertEqual(calls[-1][:2], ["k8s", "delete"])

    def test_success_requires_workflow_and_cleanup_success(self):
        status, output, calls = self.run_case()
        self.assertEqual(status, 0)
        self.assertIn("Compose smoke passed", output)
        self.assertIn("Kubernetes smoke passed", output)
        self.assertIn("Compose cleanup: passed", output)
        self.assertEqual(sum(call[:2] == ["k8s", "delete"] for call in calls), 1)

    def test_signals_preserve_status_and_attempt_cleanup_once(self):
        for requested_signal in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=requested_signal):
                status, output, calls = self.run_case(requested_signal=requested_signal, cleanup_failure=True)
                self.assertEqual(status, 128 + requested_signal)
                self.assertEqual(sum(call[:2] == ["k8s", "delete"] for call in calls), 1)
                self.assertNotIn("smoke passed", output)


if __name__ == "__main__":
    unittest.main()
