#!/usr/bin/env python3
"""Add existing shared Swift files to the app target without touching signing."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = root / 'PhoneAgent/PhoneAgent.xcodeproj/project.pbxproj'
s = p.read_text()
marker = '/* Wellphone shared calendar sources */'
# Xcode reformats PBX records and removes standalone comments. Check stable IDs.
ids = [f'FAD2000000000000000001{i:02X}' for i in range(3)]
if all(identifier in s for identifier in ids):
    print('Native calendar host source membership already configured.')
    raise SystemExit(0)
if any(identifier in s for identifier in ids):
    raise SystemExit('Partial shared source membership; review project before proceeding.')
names = ['CalendarBridge.swift', 'CalendarEventInput.swift', 'SimulatorRPCServer.swift']
records = ['\n\t\t' + marker]
for i, name in enumerate(names):
    ref = f'FAD2000000000000000000{i:02X}'
    build = f'FAD2000000000000000001{i:02X}'
    records += [f'\t\t{ref} = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = PhoneAgentUITests/{name}; sourceTree = SOURCE_ROOT; }};',
                f'\t\t{build} = {{isa = PBXBuildFile; fileRef = {ref}; }};']
s = s.replace('objects = {', 'objects = {\n' + '\n'.join(records), 1)
anchor = '12FFC0952DEACA2800C1B7A9 /* Sources */ = {'
a = s.index(anchor)
b = s.index('files = (', a) + len('files = (')
s = s[:b] + ''.join(f'\n\t\t\t\tFAD2000000000000000001{i:02X},' for i in range(3)) + s[b:]
p.write_text(s)
print('Shared original RPC and EventKit sources added to app; signing unchanged.')
