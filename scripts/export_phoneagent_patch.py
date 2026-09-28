#!/usr/bin/env python3
"""Export only Wellphone source files, never local signing edits."""
from pathlib import Path
import difflib
import subprocess

root = Path(__file__).resolve().parents[1]
repo = root / "PhoneAgent"
paths = ["PhoneAgent/PlanModels.swift", ".agents/skills/phoneagent/scripts/forward_rpc_localhost.py", "PhoneAgent/CalendarHostView.swift", "PhoneAgent/ContentView.swift", "PhoneAgent/Info.plist", "PhoneAgentUITests/CalendarBridge.swift", "PhoneAgentUITests/CalendarEventInput.swift",
         "PhoneAgentUITests/PhoneAgentUITests.swift", ".agents/skills/phoneagent/scripts/start_rpc_bridge_local.sh"]
parts = []
for name in paths:
    original = subprocess.run(["git", "show", "HEAD:" + name], cwd=repo, capture_output=True, text=True)
    before = original.stdout if original.returncode == 0 else ""
    after = (repo / name).read_text()
    parts.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
                 fromfile='a/' + name if before else '/dev/null', tofile='b/' + name))
(root / "patches/phoneagent-day3.patch").write_text(''.join(parts))
print('Exported portable patch without signing edits.')

# Also support a checked, non-destructive upgrade from the exact Day 2 patch.
import tempfile
with tempfile.TemporaryDirectory() as tmp:
    archive = subprocess.Popen(["git", "archive", "HEAD"], cwd=repo, stdout=subprocess.PIPE)
    subprocess.run(["tar", "-x", "-C", tmp], stdin=archive.stdout, check=True)
    archive.stdout.close()
    if archive.wait(): raise RuntimeError("Cannot archive pinned upstream")
    subprocess.run(["git", "apply", str(root / "patches/phoneagent-day2.patch")], cwd=tmp, check=True)
    upgrade = []
    for name in paths:
        previous = Path(tmp) / name
        before = previous.read_text() if previous.exists() else ""
        after = (repo / name).read_text()
        upgrade.extend(difflib.unified_diff(before.splitlines(True), after.splitlines(True),
            fromfile='a/' + name if before else '/dev/null', tofile='b/' + name))
    (root / "patches/phoneagent-day2-to-day3.patch").write_text(''.join(upgrade))
