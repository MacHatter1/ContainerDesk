#!/usr/bin/env python3
"""Reject filtered test runs that discovered no runnable tests."""
import sys
import xml.etree.ElementTree as ET


def require_results(path):
    cases = list(ET.parse(path).getroot().iter("testcase"))
    executed = [case for case in cases if case.find("skipped") is None]
    if not executed:
        raise ValueError(f"{path}: no tests executed (empty discovery or all skipped)")
    if any(case.find("failure") is not None or case.find("error") is not None for case in executed):
        raise ValueError(f"{path}: test failures reported")
    print(f"Verified {len(executed)} executed tests in {path}")


if __name__ == "__main__":
    for report in sys.argv[1:]:
        require_results(report)
