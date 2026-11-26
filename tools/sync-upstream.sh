#!/bin/sh
# Pull upstream changes into the two subtrees (our changes stay on top; resolve conflicts, then run
# adblock-lean/tests/test-list-conv.sh and test on a router before committing).
#   adblock-lean/  <- https://github.com/lynxthecat/adblock-lean (branch next-version)
#   luci-app/      <- https://github.com/Wildside-UK/luci-app-adblock-lean (branch main)
set -eu
cd "$(dirname "$0")/.."
git subtree pull --prefix=adblock-lean https://github.com/lynxthecat/adblock-lean.git next-version -m "Merge upstream adblock-lean next-version"
git subtree pull --prefix=luci-app https://github.com/Wildside-UK/luci-app-adblock-lean.git main -m "Merge upstream luci-app-adblock-lean"
