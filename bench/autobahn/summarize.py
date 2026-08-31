#!/usr/bin/env python3
"""What a fuzzingclient run said, in the twenty lines worth reading.

`wstest` writes one HTML page per case and an index.json beside them. The HTML
is where you go once you know which case to look at; this is what tells you
which case that is.

Autobahn's four verdicts, and what each one means here:

  OK              the case passed
  NON-STRICT      the behaviour is allowed by the RFC but not the one the suite
                  prefers. Failing fast on bad UTF-8 mid-message is the usual
                  one: nilo validates a text message when it is whole, which is
                  legal and is not what 6.4.x is looking for
  INFORMATIONAL   the suite is reporting, not judging (the 9.x timings)
  FAILED          the case is nilo's to fix
  UNIMPLEMENTED   the server did not answer at all
"""

import json
import sys
from collections import Counter

path = sys.argv[1] if len(sys.argv) > 1 else "bench/autobahn/reports/index.json"

with open(path) as f:
    index = json.load(f)

for agent, cases in index.items():
    tally = Counter(case["behavior"] for case in cases.values())
    total = sum(tally.values())
    print(f"{agent}: {total} cases")
    for verdict in ("OK", "NON-STRICT", "INFORMATIONAL", "FAILED", "UNIMPLEMENTED"):
        if tally.get(verdict):
            print(f"  {verdict:<14} {tally[verdict]}")
    for verdict in sorted(set(tally) - {"OK", "NON-STRICT", "INFORMATIONAL", "FAILED", "UNIMPLEMENTED"}):
        print(f"  {verdict:<14} {tally[verdict]}")

    def rank(name):
        return tuple(int(part) if part.isdigit() else 0 for part in name.split("."))

    interesting = sorted(
        (name for name, case in cases.items() if case["behavior"] not in ("OK", "INFORMATIONAL")),
        key=rank,
    )
    if not interesting:
        print("  nothing to look at")
        continue
    print()
    for name in interesting:
        case = cases[name]
        close = case.get("behaviorClose", "")
        print(f"  {name:<10} {case['behavior']:<14} close={close:<14} {case.get('remoteCloseCode')}")

# The exit code is what a script above this branches on: only FAILED and
# UNIMPLEMENTED are nilo's, and NON-STRICT is a documented reading rather than
# a defect.
bad = sum(
    1
    for cases in index.values()
    for case in cases.values()
    if case["behavior"] in ("FAILED", "UNIMPLEMENTED")
)
sys.exit(1 if bad else 0)
