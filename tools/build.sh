#!/bin/bash
# Compiles the development tools in this directory into build/tools.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tools
for source in tools/*.swift; do
  name="$(basename "$source" .swift)"
  swiftc -O -o "build/tools/$name" "$source"
done
echo "Built tools into build/tools"
