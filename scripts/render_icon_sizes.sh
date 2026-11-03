#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
master="$repo_root/design/beanbao-icon-master.png"
distribution="$repo_root/design/beanbao-icon-1024.png"
helper_master="$repo_root/design/beanbao-helper-icon-master.png"
helper_distribution="$repo_root/design/beanbao-helper-icon-1024.png"

test -f "$master" || { echo "Missing icon master: $master" >&2; exit 1; }
test -f "$helper_master" || { echo "Missing helper icon master: $helper_master" >&2; exit 1; }
sips -s format png -z 1024 1024 "$master" --out "$distribution" >/dev/null
sips -s format png -z 1024 1024 "$helper_master" --out "$helper_distribution" >/dev/null
cp "$distribution" "$repo_root/web/assets/beanbao-icon.png"

for component in app delivery-browser; do
    if [ "$component" = app ]; then icon="$distribution"; else icon="$helper_distribution"; fi
    for specification in '29 29' '29@2x 58' '29@3x 87' '60 60' '60@2x 120' '60@3x 180'; do
        set -- $specification
        sips -s format png -z "$2" "$2" "$icon" \
            --out "$repo_root/$component/Resources/BeanBaoIcon$1.png" >/dev/null
    done
done

echo "Rendered distinct BeanBao and BeanBao Helper icon sizes."
