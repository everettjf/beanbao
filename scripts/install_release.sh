#!/bin/sh
# Install an extracted BeanBao RootHide release on the phone.
set -eu

fail() {
    printf 'BeanBao install: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf 'Usage: sh install.sh [--dry-run]\n' >&2
    exit 2
}

dry_run=0
case "${1-}" in
    '') ;;
    --dry-run) dry_run=1 ;;
    *) usage ;;
esac
[ "$#" -le 1 ] || usage

CDPATH= cd "$(dirname "$0")" || fail 'cannot open the release directory'
[ -f SHA256SUMS ] || fail 'SHA256SUMS is missing'
for tool in sha256sum dpkg dpkg-deb dpkg-query id awk su grep; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ "$(dpkg --print-architecture)" = iphoneos-arm64e ] ||
    fail 'this release requires a RootHide iphoneos-arm64e device'
[ "$dry_run" -eq 1 ] || [ "$(id -u)" = 0 ] || fail 'run as root on the phone'

# Check every artifact before the first package changes the device.
sha256sum -c SHA256SUMS || fail 'package checksum verification failed'
[ "$(awk 'END { print NR }' SHA256SUMS)" -eq 4 ] || fail 'expected four package checksums'
for name in dev.beanbao.bridge dev.beanbao.agent dev.beanbao.deliverybrowser dev.beanbao.app; do
    set -- "$name"_*_iphoneos-arm64e.deb
    [ "$#" -eq 1 ] && [ -f "$1" ] || fail "expected exactly one package for $name"
    [ "$(awk -v file="$1" '$2 == file { count++ } END { print count + 0 }' SHA256SUMS)" -eq 1 ] ||
        fail "$1 is not uniquely listed in SHA256SUMS"
    [ "$(dpkg-deb -f "$1" Package)" = "$name" ] || fail "$1 has the wrong package ID"
    [ "$(dpkg-deb -f "$1" Architecture)" = iphoneos-arm64e ] ||
        fail "$1 has the wrong architecture"
    candidate=$(dpkg-deb -f "$1" Version)
    [ -n "$candidate" ] || fail "$1 has no version"
    installed=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)
    if [ -n "$installed" ] && dpkg --compare-versions "$installed" gt "$candidate"; then
        fail "$name $installed is newer than release version $candidate"
    fi
    if [ "$installed" = "$candidate" ]; then
        printf 'Keep %s %s\n' "$name" "$candidate"
    else
        printf 'Install %s %s (installed: %s)\n' "$name" "$candidate" "${installed:-none}"
    fi
done

if [ "$dry_run" -eq 1 ]; then
    printf 'Dry run complete; no package or service changed.\n'
    exit 0
fi

bridge_changed=0
agent_changed=0
app_changed=0
browser_changed=0
for name in dev.beanbao.bridge dev.beanbao.agent dev.beanbao.deliverybrowser dev.beanbao.app; do
    set -- "$name"_*_iphoneos-arm64e.deb
    candidate=$(dpkg-deb -f "$1" Version)
    installed=$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)
    [ "$installed" != "$candidate" ] || continue
    dpkg -i "$1" || fail "dpkg could not install $name; inspect its dependency error"
    [ "$(dpkg-query -W -f='${Version}' "$name" 2>/dev/null || true)" = "$candidate" ] ||
        fail "$name did not report the expected installed version"
    case "$name" in
        dev.beanbao.bridge) bridge_changed=1 ;;
        dev.beanbao.agent) agent_changed=1 ;;
        dev.beanbao.deliverybrowser) browser_changed=1 ;;
        dev.beanbao.app) app_changed=1 ;;
    esac
done

set -- dev.beanbao.agent_*_iphoneos-arm64e.deb
agent_version=$(dpkg-deb -f "$1" Version)
agent_status=$(su mobile -c 'beanbaoagentctl status' 2>/dev/null || true)
agent_matches() {
    printf '%s' "$agent_status" | grep -Fq '"ok":true' &&
        printf '%s' "$agent_status" | grep -Fq "\"agent_version\":\"$agent_version\""
}
if [ "$agent_changed" -eq 1 ] || ! agent_matches; then
    if command -v launchctl >/dev/null 2>&1 &&
       (launchctl kickstart -k user/501/dev.beanbao.agent ||
        { launchctl bootstrap user/501 /Library/LaunchDaemons/dev.beanbao.agent.plist &&
          launchctl kickstart -k user/501/dev.beanbao.agent; }); then
        printf 'Agent service restarted.\n'
    else
        fail 'packages installed, but the Agent service did not start; inspect launchctl before use'
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        agent_status=$(su mobile -c 'beanbaoagentctl status' 2>/dev/null || true)
        agent_matches && break
        sleep 1
    done
    agent_matches || fail "Agent package is $agent_version but its running version could not be verified"
fi
printf 'Running Agent version verified: %s\n' "$agent_version"
[ "$browser_changed" -eq 0 ] && [ "$app_changed" -eq 0 ] || {
    if command -v uicache >/dev/null 2>&1 && uicache -a; then
        printf 'App icons refreshed.\n'
    else
        printf 'Run uicache -a or reload SpringBoard later to refresh the app icons.\n' >&2
    fi
}
[ "$browser_changed" -eq 0 ] || printf 'Close and reopen BeanBao Web to load its update.\n'
[ "$app_changed" -eq 0 ] || printf 'Close and reopen BeanBao to load its update.\n'
[ "$bridge_changed" -eq 0 ] ||
    printf 'Reload SpringBoard when convenient, then unlock the phone to activate the Bridge update.\n'
printf 'BeanBao package installation complete.\n'
