#!/usr/bin/env bash
set -e

APP_DIR="/var/www/council-ai"
BRANCH="main"
LOCK_FILE="/tmp/council_ai_deploy.lock"
BACKUP_DIR="$APP_DIR/storage/app/backups/db"
BACKUP_KEEP=20
MIN_FREE_KB=200000

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Another deploy is already running."
  exit 1
fi

echo "================================"
echo "Council AI Deploy - v0.1.5"
echo "================================"

cd "$APP_DIR"

echo "[1/9] Current status"
git status --short

echo "[2/9] Check disk space"
FREE_KB=$(df -Pk "$APP_DIR" | awk 'NR==2 {print $4}')
echo "Free disk space: ${FREE_KB} KB"

if [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  echo "ERROR: Not enough free disk space for safe deploy."
  echo "Required: ${MIN_FREE_KB} KB"
  echo "Available: ${FREE_KB} KB"
  exit 1
fi

echo "[3/9] Prepare DB backup folder"
mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="$BACKUP_DIR/council_ai_${TIMESTAMP}.sql"

echo "[4/9] Create DB backup"
set -a
source .env
set +a

mysqldump \
  --host="${DB_HOST:-127.0.0.1}" \
  --port="${DB_PORT:-3306}" \
  --user="${DB_USERNAME}" \
  --password="${DB_PASSWORD}" \
  "${DB_DATABASE}" > "$BACKUP_FILE"

echo "Backup file: $BACKUP_FILE"

echo "[5/9] Validate DB backup"
if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file was not created."
  exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file is empty."
  exit 1
fi

if ! tail -n 5 "$BACKUP_FILE" | grep -q "Dump completed"; then
  echo "ERROR: Backup completion marker was not found."
  exit 1
fi

echo "DB backup validation: OK"

echo "[6/9] Rotate DB backups"
find "$BACKUP_DIR" -type f -name "council_ai_*.sql" | sort -r | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f

echo "[7/9] Fetch latest from GitHub"
git fetch origin

echo "[8/9] Reset hard to origin/$BRANCH"
git reset --hard "origin/$BRANCH"

echo "[9/9] Clear Laravel cache and show version"
php artisan optimize:clear

if [ -f VERSION ]; then
  echo "VERSION: $(cat VERSION)"
else
  echo "VERSION file not found"
fi

echo "================================"
echo "Deploy completed."
echo "================================"
