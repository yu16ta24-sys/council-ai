#!/usr/bin/env bash
set -e

APP_DIR="/var/www/council-ai"
BRANCH="main"
LOCK_FILE="/tmp/council_ai_deploy.lock"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Another deploy is already running."
  exit 1
fi

echo "================================"
echo "Council AI Deploy - v0.1.4"
echo "================================"

cd "$APP_DIR"

echo "[1/6] Current status"
git status --short

echo "[2/6] Fetch latest from GitHub"
git fetch origin

echo "[3/6] Reset hard to origin/$BRANCH"
git reset --hard "origin/$BRANCH"

echo "[4/6] Clear Laravel cache"
php artisan optimize:clear

echo "[5/6] Show version"
if [ -f VERSION ]; then
  echo "VERSION: $(cat VERSION)"
else
  echo "VERSION file not found"
fi

echo "[6/6] Done"
echo "================================"
echo "Deploy completed."
echo "================================"
