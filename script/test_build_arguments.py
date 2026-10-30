import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildArgumentsTests(unittest.TestCase):
    def invoke(self, *arguments):
        with tempfile.TemporaryDirectory(prefix="containerdesk-build-args-") as temp:
            root = Path(temp)
            (root / "script").mkdir()
            script = root / "script/build_and_run.sh"
            shutil.copyfile(Path(__file__).with_name("build_and_run.sh"), script)
            icon = root / "Sources/ContainerDeskApp/Resources/ContainerDesk.icns"
            icon.parent.mkdir(parents=True)
            icon.touch()
            tools = root / "tools"
            tools.mkdir()
            log = root / "calls"
            for name, body in {
                "pgrep": 'echo pgrep >> "$PROBE_LOG"\n',
                "swift": 'echo swift >> "$PROBE_LOG"\nexit 9\n',
            }.items():
                executable = tools / name
                executable.write_text("#!/bin/bash\n" + body)
                executable.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + ":/usr/bin:/bin", PROBE_LOG=str(log), CONTAINERDESK_BUILD_CONFIGURATION="debug")
            result = subprocess.run(["/bin/bash", str(script), *arguments], env=environment, capture_output=True, text=True)
            return result, log.read_text() if log.exists() else ""

    def test_invalid_and_extra_arguments_have_no_side_effects(self):
        for args in [("--typo",), ("run", "extra"), ("--help", "extra")]:
            with self.subTest(args=args):
                result, calls = self.invoke(*args)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(calls, "")

    def test_help_has_no_side_effects(self):
        for mode in ["--help", "-h", "help"]:
            with self.subTest(mode=mode):
                result, calls = self.invoke(mode)
                self.assertEqual(result.returncode, 0)
                self.assertIn("usage:", result.stdout)
                self.assertEqual(calls, "")

    def test_supported_modes_reach_build(self):
        for mode in ["run", "--build-only", "build-only", "--debug", "debug", "--logs", "logs", "--telemetry", "telemetry", "--navigation-metrics", "navigation-metrics", "--navigation-benchmark", "navigation-benchmark", "--verify", "verify"]:
            with self.subTest(mode=mode):
                result, calls = self.invoke(mode)
                self.assertEqual(result.returncode, 9)
                self.assertIn("swift", calls)


if __name__ == "__main__":
    unittest.main()
