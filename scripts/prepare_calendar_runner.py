#!/usr/bin/env python3
"""Add EventKit usage text to Xcode's generated runner and re-sign with its existing identity.
Does not edit Xcode templates, profiles, certificates, or the user's signing settings.
"""
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]).resolve()
simulator = sys.argv[2] == "1"
raw = subprocess.check_output([
    "xcodebuild", "-project", str(repo / "PhoneAgent.xcodeproj"), "-scheme", "PhoneAgent",
    "-configuration", "Debug", "-sdk", "iphonesimulator" if simulator else "iphoneos",
    "-showBuildSettings", "-json"], stderr=subprocess.DEVNULL)
settings = json.loads(raw)[0]["buildSettings"]
runner = Path(settings["BUILT_PRODUCTS_DIR"]) / "PhoneAgentUITests-Runner.app"
plist = runner / "Info.plist"
if not plist.is_file():
    raise SystemExit(f"Generated runner missing: {runner}")
identity = "-"
if not simulator:
    # Extract the PUBLIC leaf certificate from this already signed build, not a key.
    # Its fingerprint selects exactly the identity Xcode just used for the runner.
    with tempfile.TemporaryDirectory(prefix="wellphone-cert-") as directory:
        prefix = str(Path(directory) / "cert")
        subprocess.run(["codesign", "-d", "--extract-certificates=" + prefix, str(runner)], check=True)
        fingerprint = subprocess.check_output(["openssl", "x509", "-inform", "DER", "-in", prefix + "0",
                                               "-noout", "-fingerprint", "-sha1"], text=True)
        identity = fingerprint.strip().split("=", 1)[1].replace(":", "")
data = plistlib.loads(plist.read_bytes())
data["NSCalendarsFullAccessUsageDescription"] = "Wellphone creates test events and reads them back to verify execution."
plist.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_BINARY))
subprocess.run(["codesign", "--force", "--sign", identity, "--preserve-metadata=identifier,entitlements,flags",
                "--generate-entitlement-der", str(runner)], check=True)
subprocess.run(["codesign", "--verify", "--strict", str(runner)], check=True)
print("WELLPHONE_RUNNER_PRIVACY_READY: full calendar access description installed")
