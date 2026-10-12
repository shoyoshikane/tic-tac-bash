#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
scaffold=$(mktemp -d)
trap 'rm -rf "$scaffold"' EXIT
flutter create --no-pub --platforms android,ios,web --org com.shoyoshikane --project-name high_tension_tic_tac_toe "$scaffold/app"
for platform in android ios web; do
  if [ ! -d "$platform" ]; then cp -R "$scaffold/app/$platform" "$platform"; fi
done
if [ ! -f .metadata ]; then cp "$scaffold/app/.metadata" .metadata; fi
cp tool/web/index.html web/index.html
cp tool/web/favicon.svg tool/web/favicon.png web/
python3 tool/configure_platforms.py
python3 tool/fonts.py
flutter pub get
