#!/bin/bash
# lemmy-private-mode: switch a Lemmy instance to private mode under heavy
# load (e.g. a scraper attack) and back to public once things calm down.
#
# Run as root from cron every minute. See README.md.
#   lemmy-private-mode          normal run (from cron)
#   lemmy-private-mode status   show what it sees, change nothing
#
# Private mode (local_site.private_instance) blocks ANONYMOUS reads of the
# local API, so anonymous scraping stops costing anything. Logged-in users,
# authenticated apps and federation keep working. Written straight to
# Postgres: Lemmy caches this setting for ~1s, so it applies almost
# immediately, with no restart and no admin token.

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin

# ---------------------------------------------------------------------------
# Configuration. Override any of these in $CONFIG instead of editing here.
# ---------------------------------------------------------------------------
CONFIG="${CONFIG:-/etc/lemmy-private-mode.conf}"

ON_AT=5               # enable private mode when 1-min load >= this
OFF_AT=3              # start cooldown when 1-min load <= this
COOLDOWN_SECS=300     # load must stay <= OFF_AT this long before disabling

DB_USER=lemmy
DB_NAME=lemmy

# Command that runs one SQL statement, given as its last argument.
# Leave empty to auto-detect:
#  1. a running Docker container (name or image containing postgres,
#     pgautoupgrade or postgis) that holds the Lemmy database, else
#  2. a local psql on 127.0.0.1 (non-Docker install; password in ~/.pgpass).
# Or set it explicitly, e.g.:
#   PSQL="docker exec my-postgres psql -U lemmy -d lemmy -tAc"
#   PSQL="PGPASSWORD=secret psql -h 127.0.0.1 -U lemmy -d lemmy -tAc"
PSQL=""

SQL_TIMEOUT=20        # seconds before a database call is given up

LOG=/var/log/lemmy-private-mode.log
STATE_DIR=/var/lib/lemmy-private-mode

# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

# ---------------------------------------------------------------------------
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG"; }

# run_sql <command> <statement>: prints the result with whitespace removed
run_sql() { timeout "$SQL_TIMEOUT" bash -c "$1 \"\$1\"" _ "$2" 2>/dev/null | tr -d '[:space:]'; }
sql()     { [ -n "$PSQL" ] && run_sql "$PSQL" "$1"; }

if [ -z "$PSQL" ]; then
  probe="SELECT 1 FROM local_site LIMIT 1;"
  if command -v docker >/dev/null 2>&1; then
    for c in $(timeout "$SQL_TIMEOUT" docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null \
               | awk 'tolower($0) ~ /postgres|pgautoupgrade|postgis/ {print $1}'); do
      cand="docker exec $c psql -w -U $DB_USER -d $DB_NAME -tAc"
      if [ "$(run_sql "$cand" "$probe")" = "1" ]; then
        PSQL="$cand"; break
      fi
    done
  fi
  if [ -z "$PSQL" ] && command -v psql >/dev/null 2>&1; then
    PSQL="psql -w -h 127.0.0.1 -U $DB_USER -d $DB_NAME -tAc"
  fi
fi

ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }
le() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'; }

mkdir -p "$STATE_DIR" || exit 1
CALM_SINCE="$STATE_DIR/calm-since"       # cooldown start timestamp

# Cooldown start from the state file; empty if missing or not a number.
calm_since() {
  local v
  v=$(cat "$CALM_SINCE" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) echo "" ;; *) echo "$v" ;; esac
}

load=$(awk '{print $1}' /proc/loadavg)

if [ "$1" = "status" ]; then
  echo "database:         ${PSQL:-NOT FOUND}"
  v=$(sql "SELECT private_instance FROM local_site LIMIT 1;")
  echo "private_instance: ${v:-unknown (cannot read the database)}"
  echo "load (1 min):     $load  (on at >= $ON_AT, off at <= $OFF_AT after ${COOLDOWN_SECS}s)"
  since=$(calm_since)
  [ -n "$since" ] && echo "cooldown:         running since $(date -d "@$since" '+%H:%M:%S')"
  exit 0
fi

# One run at a time.
exec 9>"$STATE_DIR/lock" || exit 1
flock -n 9 || exit 0

current=$(sql "SELECT private_instance FROM local_site LIMIT 1;")
if [ "$current" != "t" ] && [ "$current" != "f" ]; then
  log "ERROR: could not read private_instance (got '${current}'). Database: ${PSQL:-not found}. Set PSQL in $CONFIG"
  exit 1
fi

# set_private true|false: write, then read back to confirm
set_private() {
  sql "UPDATE local_site SET private_instance = $1;" >/dev/null
  [ "$(sql "SELECT private_instance FROM local_site LIMIT 1;")" = "${1:0:1}" ]
}

if [ "$current" = "f" ]; then
  rm -f "$CALM_SINCE"
  if ge "$load" "$ON_AT"; then
    if set_private true; then
      log "load $load >= $ON_AT, ENABLED private mode"
    else
      log "ERROR: load $load >= $ON_AT but enabling private mode failed"
    fi
  fi
  exit 0
fi

# Private mode is on.
if le "$load" "$OFF_AT"; then
  since=$(calm_since)
  if [ -z "$since" ]; then
    date +%s > "$CALM_SINCE"
    log "load $load calm, starting ${COOLDOWN_SECS}s cooldown"
  else
    elapsed=$(( $(date +%s) - since ))
    if [ "$elapsed" -ge "$COOLDOWN_SECS" ]; then
      if set_private false; then
        rm -f "$CALM_SINCE"
        log "calm for ${elapsed}s, DISABLED private mode"
      else
        log "ERROR: disabling private mode failed, will retry"
      fi
    fi
  fi
else
  [ -f "$CALM_SINCE" ] && log "load $load rose again, cooldown reset"
  rm -f "$CALM_SINCE"
fi
