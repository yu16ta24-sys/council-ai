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
OLD_COMMIT=""
NEW_COMMIT=""
OLD_VERSION=""
MAINTENANCE_STATUS="not_started"
GIT_ROLLBACK_STATUS="not_attempted"
COMPOSER_RECOVERY_STATUS="not_needed"
DB_BACKUP_STATUS="not_started"
DB_BACKUP_VALID="false"
DB_BACKUP_FILE=""
DB_RESTORE_STATUS="not_attempted"
MAINTENANCE_RECOVERY_STATUS="not_attempted"
SKIP_APP_UP="false"

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

    echo "Recovery result"
    echo "--------------------------------"
    echo "old_commit: $OLD_COMMIT"
    echo "new_commit: $NEW_COMMIT"
    echo "old_version: $OLD_VERSION"
    echo "maintenance_status: $MAINTENANCE_STATUS"
    echo "git_rollback_status: $GIT_ROLLBACK_STATUS"
    echo "composer_recovery_status: $COMPOSER_RECOVERY_STATUS"
    echo "db_backup_status: $DB_BACKUP_STATUS"
    echo "db_backup_valid: $DB_BACKUP_VALID"
    echo "db_backup_file: $DB_BACKUP_FILE"
    echo "db_restore_status: $DB_RESTORE_STATUS"
    echo "skip_app_up: $SKIP_APP_UP"
    echo "maintenance_recovery_status: $MAINTENANCE_RECOVERY_STATUS"
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

    echo "Maintenance file"
    echo "--------------------------------"
    if [ -f "$APP_DIR/storage/framework/down" ]; then
      echo "storage/framework/down exists"
    else
      echo "storage/framework/down not found"
    fi
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
    tail -n 200 "$LOG_FILE" 2>&1
  } > "$DIAG_FILE"

  echo ""
  echo "ERROR: Deploy failed."
  echo "Please send this diagnostics file to Zippy/Claude:"
  echo "$DIAG_FILE"
}

restore_database_if_safe() {
  set +e

  if [ "$DB_BACKUP_VALID" != "true" ]; then
    echo "[R3] DB restore skipped: no verified backup."
    DB_RESTORE_STATUS="skipped_no_verified_backup"
    return 0
  fi

  if [ ! -f "$DB_BACKUP_FILE" ]; then
    echo "[R3] DB restore failed: backup file missing."
    DB_RESTORE_STATUS="failed_backup_missing"
    SKIP_APP_UP="true"
    return 1
  fi

  echo "[R3] Restore DB from verified backup:"
  echo "$DB_BACKUP_FILE"

  set -a
  source "$APP_DIR/.env"
  set +a

  MYSQL_PWD="${DB_PASSWORD}" mysql \
    --host="${DB_HOST:-127.0.0.1}" \
    --port="${DB_PORT:-3306}" \
    --user="${DB_USERNAME}" \
    "${DB_DATABASE}" < "$DB_BACKUP_FILE"

  if [ $? -eq 0 ]; then
    DB_RESTORE_STATUS="success"
    return 0
  else
    DB_RESTORE_STATUS="failed"
    SKIP_APP_UP="true"
    return 1
  fi
}

recover_on_error() {
  set +e

  echo "================================"
  echo "Recovery started"
  echo "================================"

  cd "$APP_DIR"

  if [ -n "$OLD_COMMIT" ]; then
    echo "[R1] Reset to old commit: $OLD_COMMIT"
    git reset --hard "$OLD_COMMIT"
    if [ $? -eq 0 ]; then
      GIT_ROLLBACK_STATUS="success"
    else
      GIT_ROLLBACK_STATUS="failed"
    fi
  else
    echo "[R1] OLD_COMMIT is empty. Skipping git rollback."
    GIT_ROLLBACK_STATUS="skipped_no_old_commit"
  fi

  echo "[R2] Composer recovery"
  COMPOSER_RECOVERY_STATUS="not_needed_currently"

  restore_database_if_safe

  if [ "$SKIP_APP_UP" = "true" ]; then
    echo "[R4] App will NOT be brought up because DB restore did not cleanly succeed."
    MAINTENANCE_RECOVERY_STATUS="skipped_due_to_db_restore_failure"
  else
    echo "[R4] Bring app up"
    php artisan up
    if [ $? -eq 0 ]; then
      MAINTENANCE_RECOVERY_STATUS="artisan_up_success"
    else
      echo "php artisan up failed. Removing maintenance file directly."
      rm -f "$APP_DIR/storage/framework/down"
      if [ ! -f "$APP_DIR/storage/framework/down" ]; then
        MAINTENANCE_RECOVERY_STATUS="direct_file_remove_success"
      else
        MAINTENANCE_RECOVERY_STATUS="direct_file_remove_failed"
      fi
    fi
  fi

  echo "================================"
  echo "Recovery finished"
  echo "================================"
}

on_error() {
  EXIT_CODE=$?
  trap - ERR
  DEPLOY_STATUS="failed"
  recover_on_error
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
echo "Council AI Deploy - v0.1.9"
echo "Log: $LOG_FILE"
echo "================================"

cd "$APP_DIR"

CURRENT_STEP="capture_old_state"
echo "[1/12] Capture old state"
OLD_COMMIT=$(git rev-parse HEAD)
if [ -f VERSION ]; then
  OLD_VERSION=$(cat VERSION)
else
  OLD_VERSION="VERSION file not found"
fi
echo "OLD_COMMIT: $OLD_COMMIT"
echo "OLD_VERSION: $OLD_VERSION"

CURRENT_STEP="current_status"
echo "[2/12] Current status"
git status --short

CURRENT_STEP="check_disk_space"
echo "[3/12] Check disk space"
FREE_KB=$(df -Pk "$APP_DIR" | awk 'NR==2 {print $4}')
echo "Free disk space: ${FREE_KB} KB"

if [ "$FREE_KB" -lt "$MIN_FREE_KB" ]; then
  echo "ERROR: Not enough free disk space for safe deploy."
  echo "Required: ${MIN_FREE_KB} KB"
  echo "Available: ${FREE_KB} KB"
  exit 1
fi

CURRENT_STEP="enable_maintenance_mode"
echo "[4/12] Enable maintenance mode"
php artisan down
MAINTENANCE_STATUS="enabled"

CURRENT_STEP="prepare_backup_folder"
echo "[5/12] Prepare DB backup folder"
mkdir -p "$BACKUP_DIR"

BACKUP_FILE="$BACKUP_DIR/council_ai_${TIMESTAMP}.sql"
DB_BACKUP_FILE="$BACKUP_FILE"

CURRENT_STEP="create_db_backup"
echo "[6/12] Create DB backup"
set -a
source .env
set +a

MYSQL_PWD="${DB_PASSWORD}" mysqldump \
  --no-tablespaces \
  --host="${DB_HOST:-127.0.0.1}" \
  --port="${DB_PORT:-3306}" \
  --user="${DB_USERNAME}" \
  "${DB_DATABASE}" > "$BACKUP_FILE"

DB_BACKUP_STATUS="created"
echo "Backup file: $BACKUP_FILE"

CURRENT_STEP="validate_db_backup"
echo "[7/12] Validate DB backup"
if [ ! -f "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file was not created."
  DB_BACKUP_STATUS="missing"
  exit 1
fi

if [ ! -s "$BACKUP_FILE" ]; then
  echo "ERROR: Backup file is empty."
  DB_BACKUP_STATUS="empty"
  exit 1
fi

if ! tail -n 5 "$BACKUP_FILE" | grep -q "Dump completed"; then
  echo "ERROR: Backup completion marker was not found."
  DB_BACKUP_STATUS="invalid_no_completion_marker"
  exit 1
fi

DB_BACKUP_VALID="true"
DB_BACKUP_STATUS="verified"
echo "DB backup validation: OK"

CURRENT_STEP="rotate_backups"
echo "[8/12] Rotate DB backups"
find "$BACKUP_DIR" -type f -name "council_ai_*.sql" | sort -r | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f

CURRENT_STEP="fetch_origin"
echo "[9/12] Fetch latest from GitHub"
git fetch origin

CURRENT_STEP="reset_to_origin"
echo "[10/12] Reset hard to origin/$BRANCH"
git reset --hard "origin/$BRANCH"
NEW_COMMIT=$(git rev-parse HEAD)

CURRENT_STEP="clear_cache"
echo "[11/12] Clear Laravel cache"
php artisan optimize:clear

CURRENT_STEP="show_version_and_up"
echo "[12/12] Show version and bring app up"
if [ -f VERSION ]; then
  echo "VERSION: $(cat VERSION)"
else
  echo "VERSION file not found"
fi

php artisan up
MAINTENANCE_STATUS="disabled"

CURRENT_STEP="rotate_diagnostics"
find "$DIAG_DIR" -type f -name "deploy_failed_*.txt" -mtime +"$DIAG_KEEP_DAYS" -delete 2>/dev/null || true

DEPLOY_STATUS="success"

echo "================================"
echo "Deploy completed."
echo "================================"
