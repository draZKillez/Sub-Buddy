#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
# Local-only beta: does not publish a release or modify the stable appcast.
APP_VERSION=0.9.1-beta.2 APP_BUILD_NUMBER=26 \
  PACKAGE_OUTPUT_DIR="$PROJECT_DIR/outputs/beta2" \
  zsh "$PROJECT_DIR/scripts/package_dmg.sh"
