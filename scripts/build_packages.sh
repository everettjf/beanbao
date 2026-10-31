#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${THEOS:?Set THEOS to a RootHide-enabled Theos checkout}"
test -f "$THEOS/makefiles/common.mk" || {
    echo "THEOS does not contain makefiles/common.mk" >&2
    exit 1
}

sh "$repo_root/scripts/test_native_policy.sh"
python3 -m unittest discover -s "$repo_root/agent" -p 'test_*.py' -q
swift test --package-path "$repo_root" --filter TextHarnessTests

for component in bridge agent-native app; do
    make -C "$repo_root/$component" package FINALPACKAGE=1 THEOS="$THEOS"
done

version_of() {
    awk '$1 == "Version:" { print $2; exit }' "$repo_root/$1/control"
}

bridge_deb="$repo_root/bridge/packages/dev.beanbao.bridge_$(version_of bridge)_iphoneos-arm64e.deb"
agent_deb="$repo_root/agent-native/packages/dev.beanbao.agent_$(version_of agent-native)_iphoneos-arm64e.deb"
app_deb="$repo_root/app/packages/dev.beanbao.app_$(version_of app)_iphoneos-arm64e.deb"

for package in "$bridge_deb" "$agent_deb" "$app_deb"; do
    test -f "$package" || {
        echo "Missing package: $package" >&2
        exit 1
    }
done

python3 "$repo_root/scripts/audit_bridge_package.py" "$bridge_deb"
echo "Built packages (SHA-256):"
shasum -a 256 "$bridge_deb" "$agent_deb" "$app_deb"
