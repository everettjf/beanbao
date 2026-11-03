#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
master="$repo_root/design/beanbao-icon-master.png"
distribution="$repo_root/design/beanbao-icon-1024.png"

test -f "$master" || { echo "Missing icon master: $master" >&2; exit 1; }
sips -s format png -z 1024 1024 "$master" --out "$distribution" >/dev/null
cp "$distribution" "$repo_root/web/assets/beanbao-icon.png"

for component in app delivery-browser; do
    for specification in '29 29' '29@2x 58' '29@3x 87' '60 60' '60@2x 120' '60@3x 180'; do
        set -- $specification
        sips -s format png -z "$2" "$2" "$distribution" \
            --out "$repo_root/$component/Resources/BeanBaoIcon$1.png" >/dev/null
    done
done

echo "Rendered BeanBao icon sizes for the website and both applications."
