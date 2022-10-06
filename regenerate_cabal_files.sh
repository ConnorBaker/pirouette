#! /usr/env bash

NEW_TAG=$(nix flake metadata --json | jq -r '.locks.nodes."tasty-json".locked.rev')
NEW_SHA=$(nix flake metadata --json | jq -r '.locks.nodes."tasty-json".locked.narHash')
cat <<EOF > cabal.project
packages: .
source-repository-package
  type: git
  location: https://github.com/connorbaker/tasty-json.git
  tag: $NEW_TAG
  subdir: tasty-json-reporter
  --sha256: $NEW_SHA
EOF

# This file isn't committed
TASTY_JSON_PATH=$(nix flake metadata github:connorbaker/tasty-json/$NEW_TAG --json | jq -r .path)
cat <<EOF > cabal.project.local
packages: . $TASTY_JSON_PATH/tasty-json-reporter
EOF

cabal freeze

hpack