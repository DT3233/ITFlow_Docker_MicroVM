#!/bin/bash
# First boot: create the database, import the ITFlow schema, write config.php.
# Later boots: skip straight to starting services. Never deletes or overwrites existing data.
set -euo pipefail

APP=/var/www/itflow
MARKER=/var/lib/itflow-init.done
LOG=/var/log/itflow-entrypoint.log

# On any failure: report where, and if ITFLOW_DEBUG_HOLD=1, stay alive so you can
# open a console (doctl compute microvm console <id>) and read $LOG.
# Set up first, so the hold also covers the logging setup below.
fail() {
    echo "ENTRYPOINT FAILED: $1" >&2
    if [ "${ITFLOW_DEBUG_HOLD:-0}" = "1" ]; then
        echo "ITFLOW_DEBUG_HOLD=1: holding container open for debugging. Log: $LOG" >&2
        exec sleep infinity
    fi
    exit 1
}
trap 'fail "line $LINENO: $BASH_COMMAND (exit $?)"' ERR

# Docker always provides /dev/fd and /dev/std*, other runtimes may not. The log tee
# below (process substitution) and supervisord's /dev/fd/1 log targets need them.
[ -e /dev/fd ] || ln -s /proc/self/fd /dev/fd
[ -e /dev/stdin ] || ln -s /proc/self/fd/0 /dev/stdin
[ -e /dev/stdout ] || ln -s /proc/self/fd/1 /dev/stdout
[ -e /dev/stderr ] || ln -s /proc/self/fd/2 /dev/stderr

# Keep a copy of first-boot output inside the VM (DO has no log viewer).
# fds 3/4 save the real stdout/stderr so supervisord's output is NOT tee'd later.
exec 3>&1 4>&2
exec > >(tee -a "$LOG") 2>&1
echo "=== entrypoint start $(date -Is) uid=$(id -u) ==="

# DO MicroVMs mount an empty tmpfs on /run, hiding the image's /run/lock, so
# /var/lock (-> /run/lock) dangles. Recreate it as Debian ships it.
mkdir -p /run/lock
chmod 1777 /run/lock

mkdir -p /run/mysqld /var/run/apache2 /var/lock/apache2 /var/run/tailscale /var/lib/tailscale /var/backups/itflow
chown mysql:mysql /run/mysqld
chmod 700 /var/lib/tailscale /var/backups/itflow

if [ ! -f "$MARKER" ]; then
    if [ -f "$APP/config.php" ]; then
        echo "config.php already exists; treating as initialized and leaving it alone."
        touch "$MARKER"
    else
        echo "First boot: initializing ITFlow database..."

        if [ ! -d /var/lib/mysql/mysql ]; then
            mariadb-install-db --user=mysql --datadir=/var/lib/mysql >/dev/null
        fi

        # Temporary MariaDB, no network access, just for setup
        mariadbd --user=mysql --skip-networking &
        dbpid=$!
        for _ in $(seq 1 60); do
            if mariadb-admin ping --silent 2>/dev/null; then break; fi
            sleep 1
        done
        if ! mariadb-admin ping --silent 2>/dev/null; then
            fail "MariaDB did not start within 60 seconds"
        fi

        DBPASS=$(openssl rand -hex 24)
        INSTALL_ID=$(openssl rand -hex 16)
        BASE_URL="${ITFLOW_BASE_URL:-localhost}"

        mariadb <<SQL
CREATE DATABASE IF NOT EXISTS itflow CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'itflow'@'localhost' IDENTIFIED BY '${DBPASS}';
ALTER USER 'itflow'@'localhost' IDENTIFIED BY '${DBPASS}';
GRANT ALL PRIVILEGES ON itflow.* TO 'itflow'@'localhost';
FLUSH PRIVILEGES;
SQL

        # Import the schema only into an empty database
        TABLES=$(mariadb -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='itflow';")
        if [ "$TABLES" = "0" ]; then
            # Drop the dump's "sandbox mode" first line if present; older clients reject it
            sed '1{/^\/\*M!999999/d}' "$APP/db.sql" | mariadb itflow
        fi

        umask 027
        cat > "$APP/config.php" <<PHP
<?php
\$dbhost = 'localhost';
\$dbusername = 'itflow';
\$dbpassword = '${DBPASS}';
\$database = 'itflow';
\$mysqli = mysqli_connect(\$dbhost, \$dbusername, \$dbpassword, \$database) or die('Database Connection Failed');
\$config_app_name = 'ITFlow';
\$config_base_url = '${BASE_URL}';
\$config_https_only = false;
\$repo_branch = 'master';
\$installation_id = '${INSTALL_ID}';
PHP
        chown www-data:www-data "$APP/config.php"
        chmod 640 "$APP/config.php"
        umask 022

        mariadb-admin shutdown
        wait "$dbpid" || true

        touch "$MARKER"
        echo "First boot setup complete."
    fi
fi

echo "=== starting supervisord $(date -Is) ==="
trap - ERR

# Debug hold also covers supervisord: run it as a child (output still tee'd to $LOG),
# and if it exits, record the code and stay alive for the console.
if [ "${ITFLOW_DEBUG_HOLD:-0}" = "1" ]; then
    exec 3>&- 4>&-
    rc=0
    /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf || rc=$?
    echo "supervisord exited with code $rc at $(date -Is); ITFLOW_DEBUG_HOLD=1: holding. Log: $LOG" >&2
    exec sleep infinity
fi

exec 1>&3 2>&4 3>&- 4>&-
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
