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
state_path = Path(os.environ["CONTAINERDESK_SMOKE_MOCK_STATE"])
state = json.loads(state_path.read_text())
creation = None
if args[:2] == ["network", "create"]: creation = ("network", args[-1])
elif args[:2] == ["volume", "create"]: creation = ("volume", args[-1])
elif args[0] == "run": creation = ("container", args[args.index("--name") + 1])
elif args[0] == "build": creation = ("image", args[args.index("--tag") + 1])
elif args[:2] == ["image", "tag"]: creation = ("image", args[-1])
fault = bool(creation) and args[:len(json.loads(os.environ["CONTAINERDESK_SMOKE_MOCK_CREATE_FAULT"]))] == json.loads(os.environ["CONTAINERDESK_SMOKE_MOCK_CREATE_FAULT"])
if fault and os.environ["CONTAINERDESK_SMOKE_MOCK_FAULT_MODE"] == "before": sys.exit(8)
if creation:
    kind, name = creation
    state.setdefault(kind, []).append(name)
    state_path.write_text(json.dumps(state))
if fault:
    mode = os.environ["CONTAINERDESK_SMOKE_MOCK_FAULT_MODE"]
    if mode == "after": sys.exit(8)
    if mode.startswith("signal:"): os.kill(os.getppid(), int(mode.split(":")[1]))
if cleanup and (os.environ["CONTAINERDESK_SMOKE_MOCK_CLEANUP_FAILURE"] == "1" or
                (args[:2] == ["image", "delete"] and os.environ["CONTAINERDESK_SMOKE_MOCK_IMAGE_DELETE_FAILURE"] == "1")):
    print("simulated cleanup failure", file=sys.stderr)
    sys.exit(9)
if cleanup and "delete" in args:
    kind = "container" if args[0] == "delete" else args[0]
    if args[-1] not in state.get(kind, []): sys.exit(9)
    state[kind] = [name for name in state.get(kind, []) if name != args[-1]]
    state_path.write_text(json.dumps(state))
if args[:2] == ["builder", "status"]:
    print('[{"id":"buildkit","status":{"state":"running"}}]')
elif args[0] == "list" or (len(args) > 1 and args[1] == "list"):
    kind = "container" if args[0] == "list" else args[0]
    if kind == "image":
        domain = os.environ["CONTAINERDESK_SMOKE_MOCK_IMAGE_DOMAIN"]
        print(json.dumps([{"configuration": {"name": domain + "/library/" + name if domain else name}, "displayReference": name if os.environ["CONTAINERDESK_SMOKE_MOCK_IMAGE_METADATA_VALID"] == "1" else None} for name in state.get(kind, [])]))
    else:
        print(json.dumps([{"id": name, "configuration": {"id": name, "name": name}} for name in state.get(kind, [])]))
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
                 requested_signal=None, keep=False, create_fault=(), fault_mode="",
                 image_domain="", image_delete_failure=False, initial_images=(), image_metadata_valid=True):
        calls_path = self.root / "calls.jsonl"
        output_path = self.root / "console.log"
        calls_path.write_text("")
        state_path = self.root / "resources.json"
        state_path.write_text(json.dumps({"image": list(initial_images)}))
        env = dict(os.environ, CONTAINER_CLI=str(self.mock),
                   CONTAINERDESK_SMOKE_MOCK_LOG=str(calls_path),
                   CONTAINERDESK_SMOKE_MOCK_OUTPUT=str(output_path),
                   CONTAINERDESK_SMOKE_MOCK_OPERATION_FAILURE=str(int(operation_failure)),
                   CONTAINERDESK_SMOKE_MOCK_CLEANUP_FAILURE=str(int(cleanup_failure)),
                   CONTAINERDESK_SMOKE_MOCK_IMAGE_DELETE_FAILURE=str(int(image_delete_failure)),
                   CONTAINERDESK_SMOKE_MOCK_IMAGE_DOMAIN=image_domain,
                   CONTAINERDESK_SMOKE_MOCK_IMAGE_METADATA_VALID=str(int(image_metadata_valid)),
                   CONTAINERDESK_SMOKE_MOCK_STATE=str(state_path),
                   CONTAINERDESK_SMOKE_MOCK_CREATE_FAULT=json.dumps(create_fault or ["never-match"]),
                   CONTAINERDESK_SMOKE_MOCK_FAULT_MODE=fault_mode,
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

    def test_partial_creation_failures_remove_every_generated_resource(self):
        for operation in [("network", "create"), ("volume", "create"), ("run",), ("build",), ("image", "tag")]:
            with self.subTest(operation=operation):
                status, _, _ = self.run_case(create_fault=operation, fault_mode="after")
                self.assertEqual(status, 8)
                self.assertTrue(all(not names for names in json.loads((self.root / "resources.json").read_text()).values()))

    def test_signals_at_each_creation_boundary_remove_generated_resources(self):
        for operation in [("network", "create"), ("volume", "create"), ("run",), ("build",), ("image", "tag")]:
            for sig in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(operation=operation, signal=sig):
                    status, _, _ = self.run_case(create_fault=operation, fault_mode=f"signal:{int(sig)}")
                    self.assertEqual(status, 128 + sig)
                    self.assertTrue(all(not names for names in json.loads((self.root / "resources.json").read_text()).values()))

    def test_no_side_effect_before_failure_is_an_idempotent_cleanup_case(self):
        status, output, _ = self.run_case(create_fault=("volume", "create"), fault_mode="before")
        self.assertEqual(status, 8)
        self.assertNotIn("Smoke cleanup incomplete", output)

    def test_success_requires_completed_cleanup(self):
        status, output, cleanup = self.run_case()
        self.assertEqual(status, 0)
        self.assertEqual(len(cleanup), 6)
        self.assertIn("Smoke checks and cleanup passed.", output)

    def test_cleanup_failure_fails_the_run_and_attempts_every_resource(self):
        status, output, cleanup = self.run_case(cleanup_failure=True)
        self.assertEqual(status, 1)
        self.assertEqual(len(cleanup), 6)
        self.assertEqual(output.count("Smoke cleanup failed:"), 5)
        self.assertIn("Smoke cleanup incomplete", output)
        self.assertNotIn("Smoke checks and cleanup passed.", output)

    def test_failed_image_deletes_cannot_pass_with_canonical_inventory(self):
        for domain in ["docker.io", "registry-1.docker.io", "registry.example.test:5000"]:
            with self.subTest(domain=domain):
                status, output, _ = self.run_case(image_domain=domain, image_delete_failure=True,
                                                 initial_images=["unrelated:existing"])
                self.assertEqual(status, 1)
                self.assertIn("Smoke cleanup incomplete", output)
                self.assertNotIn("Smoke checks and cleanup passed.", output)
                self.assertEqual(len(json.loads((self.root / "resources.json").read_text())["image"]), 3)

    def test_absent_image_is_verified_without_mistaking_an_unrelated_canonical_image(self):
        status, output, _ = self.run_case(image_domain="registry.example.test:5000",
                                         image_delete_failure=True, initial_images=["unrelated:existing"],
                                         create_fault=("build",), fault_mode="before")
        self.assertEqual(status, 8)
        self.assertNotIn("Smoke cleanup incomplete", output)
        self.assertEqual(json.loads((self.root / "resources.json").read_text())["image"], ["unrelated:existing"])

    def test_missing_image_display_metadata_cannot_prove_absence(self):
        status, output, _ = self.run_case(image_domain="docker.io", image_delete_failure=True,
                                         image_metadata_valid=False)
        self.assertEqual(status, 1)
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
        self.assertEqual(output.count("Smoke cleanup failed:"), 3)

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
