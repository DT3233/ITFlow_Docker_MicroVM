#!/bin/bash
# Makes a backup (database + uploads + config.php) if the newest one is older than ~23 hours.
# Runs hourly from cron, so it catches up whenever the MicroVM is awake.
# Keeps 14 days of backups. Only ever deletes files matching itflow-*.tar.gz in DIR.
set -euo pipefail

DIR=/var/backups/itflow
APP=/var/www/itflow
mkdir -p "$DIR"
chmod 700 "$DIR"

if [ -n "$(find "$DIR" -maxdepth 1 -name 'itflow-*.tar.gz' -mmin -1380 -print -quit)" ]; then
    exit 0
fi

STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mariadb-dump --single-transaction --routines --triggers itflow > "$TMP/itflow.sql"
cp "$APP/config.php" "$TMP/config.php"

if [ -d "$APP/uploads" ]; then
    tar -czf "$DIR/itflow-$STAMP.tar.gz.part" -C "$TMP" itflow.sql config.php -C "$APP" uploads
else
    tar -czf "$DIR/itflow-$STAMP.tar.gz.part" -C "$TMP" itflow.sql config.php
fi
mv "$DIR/itflow-$STAMP.tar.gz.part" "$DIR/itflow-$STAMP.tar.gz"
chmod 600 "$DIR/itflow-$STAMP.tar.gz"

find "$DIR" -maxdepth 1 -name 'itflow-*.tar.gz' -mtime +14 -delete
echo "$(date -Is) backup written: itflow-$STAMP.tar.gz"
