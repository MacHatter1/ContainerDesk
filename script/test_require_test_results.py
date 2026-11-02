import tempfile
from pathlib import Path
import unittest
from require_test_results import require_results


class TestExecutedResults(unittest.TestCase):
    def check(self, xml):
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / 'tests.xml'
            report.write_text(xml)
            require_results(report)

    def test_empty_or_skipped_discovery_fails(self):
        for xml in ['<testsuites/>', '<testsuite><testcase><skipped/></testcase></testsuite>']:
            with self.assertRaises(ValueError):
                self.check(xml)

    def test_failure_fails(self):
        with self.assertRaises(ValueError):
            self.check('<testsuite><testcase><failure/></testcase></testsuite>')

    def test_real_test_passes(self):
        self.check('<testsuite><testcase name="live"/></testsuite>')
