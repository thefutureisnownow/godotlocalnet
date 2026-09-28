#!/bin/sh
# Publishes addons/localnet on its own to the `addon` branch, which games pull with
# git subtree (for example Snoek'em's tools/update_localnet.sh). Run the tests first:
#   godot --headless --path . --script tests/test_localnet.gd
#   godot --headless --path . --script tests/test_demo.gd
set -e
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
	echo "Commit your changes before publishing." >&2
	exit 1
fi
split=$(git subtree split --prefix=addons/localnet)
git branch -f addon "$split"
git push origin addon
echo "Published LocalNet $(cat addons/localnet/VERSION) as addon branch $(git rev-parse --short addon)"
