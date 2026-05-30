#!/usr/bin/env bash
set -e

APP_DIR="/var/www/council-ai"
BRANCH="main"

echo "================================"
echo "Council AI Deploy - Initial"
echo "================================"

cd "$APP_DIR"

echo "[1/5] Current status"
git status --short

echo "[2/5] Fetch latest from GitHub"
git fetch origin

echo "[3/5] Reset to origin/$BRANCH"
git reset --hard "origin/$BRANCH"

echo "[4/5] Clear Laravel cache"
php artisan optimize:clear

echo "[5/5] Show version"
if [ -f VERSION ]; then
  echo "VERSION: $(cat VERSION)"
else
  echo "VERSION file not found"
fi

echo "================================"
echo "Deploy completed."
echo "================================"
