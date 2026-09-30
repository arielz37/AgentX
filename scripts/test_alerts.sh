#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -p 'test_*.py'
TASK_TMP=$(mktemp -d /tmp/wellphone-alert-tests.XXXXXX)
trap 'rm -rf "$TASK_TMP"' EXIT
COMMON=(PhoneAgent/PhoneAgentUITests/CalendarFeatures.swift PhoneAgent/PhoneAgentUITests/AdaptiveAlerts.swift PhoneAgent/PhoneAgentUITests/CalendarEventInput.swift)
SWIFTC=(xcrun swiftc -module-cache-path /tmp/wellphone-swift-cache)
for TEST in calendar_validation day3_validation alerts_validation calendar_features_validation; do
  "${SWIFTC[@]}" "${COMMON[@]}" PhoneAgent/PhoneAgent/PlanModels.swift "tests/$TEST.swift" -o "$TASK_TMP/$TEST"
  "$TASK_TMP/$TEST"
done
"${SWIFTC[@]}" -emit-library -emit-module -module-name EventKit tests/support/EventKitStub.swift -emit-module-path "$TASK_TMP/EventKit.swiftmodule" -o "$TASK_TMP/libEventKit.dylib"
"${SWIFTC[@]}" -I "$TASK_TMP" -L "$TASK_TMP" -lEventKit -Xlinker -rpath -Xlinker "$TASK_TMP" "${COMMON[@]}" PhoneAgent/PhoneAgentUITests/CalendarBridge.swift tests/alerts_bridge_validation.swift -o "$TASK_TMP/bridge-tests"
"$TASK_TMP/bridge-tests"
