#!/usr/bin/env bash
# Copy checkout sources with the root/nested exclusions used by .dockerignore.
set -euo pipefail
tar -C "${1:?Source tree required}" --exclude='./.git' --exclude='./build' --exclude='*/build' \
  --exclude='./dist' --exclude='./.venv*' --exclude='./.pub-cache' \
  --exclude='./.dart_tool' --exclude='*/.dart_tool' --exclude='./test-results' \
  --exclude='./coverage' --exclude='./models/local' --exclude='*/__pycache__' \
  --exclude='*.pyc' --exclude='*.db*' --exclude='*.log' \
  --exclude='./.env*' --exclude='google-client*.json' \
  --exclude='./.coverage' --exclude='./.coverage.*' -cf - . | tar -C "${2:?Destination required}" -xf -
