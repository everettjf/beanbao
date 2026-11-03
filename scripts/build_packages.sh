#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${THEOS:?Set THEOS to a RootHide-enabled Theos checkout}"
test -f "$THEOS/makefiles/common.mk" || {
    echo "THEOS does not contain makefiles/common.mk" >&2
    exit 1
}

sh "$repo_root/scripts/test_native_policy.sh"
sh "$repo_root/scripts/test_activity_store.sh"
python3 -m unittest discover -s "$repo_root/agent" -p 'test_*.py' -q
python3 "$repo_root/tests/test_delivery_browser_js.py" -q
python3 "$repo_root/tests/test_release_installer.py" -q
python3 "$repo_root/tests/test_install_to_device.py" -q
swift test --package-path "$repo_root"

for component in bridge agent-native delivery-browser app; do
    make -C "$repo_root/$component" package FINALPACKAGE=1 THEOS="$THEOS"
done

version_of() {
    awk '$1 == "Version:" { print $2; exit }' "$repo_root/$1/control"
}

bridge_deb="$repo_root/bridge/packages/dev.beanbao.bridge_$(version_of bridge)_iphoneos-arm64e.deb"
agent_deb="$repo_root/agent-native/packages/dev.beanbao.agent_$(version_of agent-native)_iphoneos-arm64e.deb"
app_deb="$repo_root/app/packages/dev.beanbao.app_$(version_of app)_iphoneos-arm64e.deb"
browser_deb="$repo_root/delivery-browser/packages/dev.beanbao.deliverybrowser_$(version_of delivery-browser)_iphoneos-arm64e.deb"

for package in "$bridge_deb" "$agent_deb" "$app_deb" "$browser_deb"; do
    test -f "$package" || {
        echo "Missing package: $package" >&2
        exit 1
    }
done

python3 "$repo_root/scripts/audit_bridge_package.py" "$bridge_deb"
python3 "$repo_root/scripts/audit_release_packages.py" "$bridge_deb" "$agent_deb" "$app_deb" "$browser_deb"
echo "Built packages (SHA-256):"
shasum -a 256 "$bridge_deb" "$agent_deb" "$app_deb" "$browser_deb"
