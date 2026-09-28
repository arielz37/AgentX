#!/usr/bin/env python3
"""Preparation only: build/install/launch native host, reuse PhoneAgent forwarding.
Never call while the user is gaming: this deliberately opens the host app.
"""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--udid', required=True, help='Actual physical identifier from xcrun xctrace list devices')
args = parser.parse_args()
with socket.socket() as sock:
    sock.bind(('127.0.0.1', 45678))  # Fail before opening any app if another bridge owns the port.
subprocess.run([sys.executable, str(root/'scripts/configure_native_host.py')], check=True)
base = ['xcodebuild', '-project', str(root/'PhoneAgent/PhoneAgent.xcodeproj'), '-scheme', 'PhoneAgent',
        '-configuration', 'Debug', '-destination', 'id=' + args.udid, '-allowProvisioningUpdates']
subprocess.run(base + ['build'], check=True)
raw = subprocess.check_output(base + ['-showBuildSettings', '-json'], stderr=subprocess.DEVNULL)
settings = json.loads(raw)[0]['buildSettings']
app = Path(settings['BUILT_PRODUCTS_DIR'])/settings['FULL_PRODUCT_NAME']
subprocess.run(['xcrun','devicectl','device','install','app','--device',args.udid,str(app)],check=True)
subprocess.run(['xcrun','devicectl','device','process','launch','--device',args.udid,
                '--terminate-existing',settings['PRODUCT_BUNDLE_IDENTIFIER'],'--wellphone-calendar-host'],check=True)
print('Native host launched WITHOUT XCTest or debugger. Forwarding via upstream PhoneAgent.',flush=True)
try:
    subprocess.run([sys.executable,str(root/'PhoneAgent/.agents/skills/phoneagent/scripts/forward_rpc_localhost.py'),
                    '--udid',args.udid],check=True)
except KeyboardInterrupt:
    pass
