#! /usr/env bash

set -exo pipefail

CURRENT_TAG=$(nix flake metadata --json | jq -r '.locks.nodes."tasty-json".locked.rev')
CURRENT_SHA=$(nix flake metadata --json | jq -r '.locks.nodes."tasty-json".locked.narHash')
TASTY_JSON_PATH=$(nix flake metadata github:connorbaker/tasty-json/$CURRENT_TAG --json | jq -r .path)

cat <<EOF > cabal.project
packages: .
jobs: \$ncpus
source-repository-package
  type: git
  location: https://github.com/connorbaker/tasty-json.git
  tag: $CURRENT_TAG
  subdir: tasty-json-reporter
  --sha256: $CURRENT_SHA
EOF

# This file isn't committed
cat <<EOF > cabal.project.local
packages: . $TASTY_JSON_PATH/tasty-json-reporter
EOF

cabal freeze

hpack