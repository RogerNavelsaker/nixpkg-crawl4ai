#!/usr/bin/env bash
# Bump crawl4ai to the latest upstream vX.Y.Z tag: version strings, pinned rev, uv.lock, flake input.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
repo=unclecode/crawl4ai
tag=$(git ls-remote --tags --refs "https://github.com/$repo" | awk '{sub("refs/tags/","",$2); print $2}' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n1)
new=${tag#v}
old=$(grep -oE '^      version = "[^"]+"' flake.nix | sed -E 's/.*"([^"]+)"/\1/')
[ "$new" != "$old" ] || { echo "up to date: $old"; exit 0; }
rev=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag^{}" | awk '{print $1}')
[ -n "$rev" ] || rev=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" | awk '{print $1}')
oldrev=$(grep -oE '^      revision = "[0-9a-f]{40}"' flake.nix | sed -E 's/.*"([^"]+)"/\1/')
sed -i -e "s/$oldrev/$rev/g" -e "s/\"$old\"/\"$new\"/g" flake.nix
sed -i -E -e "s/^version = \"$old\"/version = \"$new\"/" -e "s/crawl4ai==$old/crawl4ai==$new/" pyproject.toml
nix run nixpkgs#uv -- lock
nix flake update crawl4ai-src
echo "bumped $old -> $new ($rev)"
