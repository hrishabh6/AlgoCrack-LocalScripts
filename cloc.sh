#!/usr/bin/env bash

set -e

echo "======================================"
echo "   LOC Report (Next.js + Spring Boot)"
echo "======================================"
echo

cloc . \
  --include-lang=Java,TypeScript,JavaScript,TSX,JSX \
  --exclude-dir=.git,node_modules,.next,out,dist,build,target,.turbo,.idea,.vscode,coverage,generated \
  --exclude-ext=json,lock,map,md,yml,yaml,properties,svg,png,jpg,jpeg,gif,ico,woff,woff2,ttf \
  --quiet


echo
echo "======================================"
echo "Done."
