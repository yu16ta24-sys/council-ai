#!/usr/bin/env bash
set -eE

APP_DIR="/var/www/council-ai"
BRANCH="main"
LOCK_FILE="/tmp/council_ai_deploy.lock"
BACKUP_DIR="$APP_DIR/storage/app/backups/db"
DIAG_DIR="$APP_DIR/storage/app/deploy_diagnostics"
LOG_DIR="$APP_DIR/storage/app/deploy_logs"
BACKUP_KEEP=20
DIAG_KEEP_DAYS=30
MIN_FREE_KB=200000

CURRENT_STEP="start"
DEPLOY_STATUS="running"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="$LOG_DIR/deploy_${TIMESTAMP}.log"
DIAG_FILE="$DIAG_DIR/deploy_failed_${TIMESTAMP}.txt"

mkdir -p "$DIAG_DIR" "$LOG_DIR"

exec > >(tee -a "$LOG_FILE") 2>&1

make_diagnostics() {
  set +e

  echo "================================"
  echo "Creating diagnostics bundle..."
  echo "Diagnostics: $DIAG_FILE"
  echo "================================"

  {
    echo "Council AI Deploy Diagnostics"
    echo "================================"
    echo "datetime: $(date)"
    echo "status: failed"
    echo "failed_step: $CURRENT_STEP"
    echo "app_dir: $APP_DIR"
    echo "branch: $BRANCH"
    echo "deploy_log: $LOG_FILE"
    echo ""

    echo "VERSION"
    echo "--------------------------------"
    if [ -f "$APP_DIR/VERSION" ]; then
      cat "$APP_DIR/VERSION"
    else
      echo "VERSION file not found"
    fi
    echo ""

    echo "Git current commit"
    echo "--------------------------------"
    cd "$APP_DIR" && git rev-parse HEAD 2>&1
    echo ""

    echo "Git status"
    echo "--------------------------------"
    cd "$APP_DIR" && git status --short 2>&1
    echo ""

    echo "Git log -1"
    echo "--------------------------------"
    cd "$APP_DIR" && git log -1 --oneline 2>&1
    echo ""

    echo "Migration status"
    echo "--------------------------------"
    cd "$APP_DIR" && php artisan migrate:status 2>&1
    echo ""

    echo "DB backup files"
    echo "--------------------------------"
    ls -lah "$BACKUP_DIR" 2>&1
    echo ""

    echo "Disk usage"
    echo "--------------------------------"
    df -h "$APP_DIR" 2>&1
    echo ""

    echo "Last deploy log tail"
    echo "--------------------------------"
    tail -n 120 "$LOG_FILE" 2>&1
  } > "$DIAG_FILE"

  echo ""
  echo "ERROR: Deploy failed."
  echo "Please send this diagnostics file to Zippy/Claude:"
  echo "$DIAG_FILE"
}

on_error() {
  EXIT_CODE=$?
  DEPLOY_STATUS="failed"
  make_diagnostics
  exit $EXIT_CODE
}

trap on_error ERR

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "ERROR: Another deploy is already running."
  exit 1
fi

echo "================================"
echo "Council AI Deploy - v0.1.7"
echo "Log: $LOG_FILE"
echo "================================"

cd "$APP_DIR"

CURRENT_STEP="current_status"
echo "[1/10] Current status"
git status --short

CURRENT_STEP="check_disk_space"
echo "[2/10] Check disk space"
FREE_KB=$(df -Pk "$APP_DIR" | awk 'NR==2 {print $4}')
echo "Free disk space: ${FREE_KB} KB"

if [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  echo "ERROR: Not enough free disk space for safe deploy."
  echo "Required: ${MIN_FREE_KB} KB"
  echo "Available: ${FREE_KB} KB"
  exit 1
fi

CURRENT_STEP="prepare_backup_folder"
echo "[3/10] Prepare DB backup folder"
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/council_ai_${TIMESTAMP}.sql"

CURRENT_STEP="create_db_backup"
echo "[4/10] Create DB backup"
set -a
source .env
set +a

mysqldump \
  --no-tablespaces \
  --host="${DB_HOST:-127.0.0.1}" \
  --port="${DB_PORT:-3306}" \
  --user="${DB_USERNAME}" \
  --password="${DB_PASSWORD}" \
  "${DB_DATABASE}" > "$BACKUP_FILE"

echo "Backup file: $BACKUP_FILE"

CURRENT_STEP="validate_db_backup"
echo "[5/10] Validate DB backup"
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

CURRENT_STEP="rotate_backups"
echo "[6/10] Rotate DB backups"
find "$BACKUP_DIR" -type f -name "council_ai_*.sql" | sort -r | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f

CURRENT_STEP="fetch_origin"
echo "[7/10] Fetch latest from GitHub"
git fetch origin

CURRENT_STEP="reset_to_origin"
echo "[8/10] Reset hard to origin/$BRANCH"
git reset --hard "origin/$BRANCH"

CURRENT_STEP="clear_cache"
echo "[9/10] Clear Laravel cache"
php artisan optimize:clear

CURRENT_STEP="show_version"
echo "[10/10] Show version"
if [ -f VERSION ]; then
  echo "VERSION: $(cat VERSION)"
else
  echo "VERSION file not found"
fi

CURRENT_STEP="rotate_diagnostics"
find "$DIAG_DIR" -type f -name "deploy_failed_*.txt" -mtime +"$DIAG_KEEP_DAYS" -delete 2>/dev/null || true

DEPLOY_STATUS="success"

echo "================================"
echo "Deploy completed."
echo "================================"
