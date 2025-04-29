#!/bin/sh

##############################################################################
# Script: poudriere_build.sh
# Version: 1.13
# Author: Karim Mansur
# Description:
#   - Automates package builds using Poudriere.
#   - Checks for a new version of this script on GitHub before execution.
#   - Supports parameters:
#       -j <jail-name>     : jail name (default: systembase)
#       -p <pkglist-name>  : package list file name (default: pkglist)
#       -l <days>          : number of days to keep logs (default: 7)
#   - Updates the ports tree, builds packages, sends a report by email, and cleans old packages.
#   - Supports concurrent jail execution using lockf with controlled re-execution.
##############################################################################

# Configurable variables
EMAIL_RECIPIENT="monitor@domain.com.br"

SCRIPT_URL="https://raw.githubusercontent.com/kmansur/poudriere/main/scripts/poudriere_build.sh"
SCRIPT_PATH="$(realpath "$0")"

check_for_update() {
  TMPFILE=$(mktemp)

  if fetch -q -o "$TMPFILE" "$SCRIPT_URL"; then
    if ! diff -q "$SCRIPT_PATH" "$TMPFILE" >/dev/null 2>&1; then
      echo "[INFO] Update detected. Updating the script..."
      cp "$TMPFILE" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "[INFO] Script updated. Restarting execution..."
      exec "$SCRIPT_PATH" "$@"
      exit 0
    else
      echo "[INFO] No update available."
    fi
  else
    echo "[ERROR] Failed to check for script update."
  fi

  rm -f "$TMPFILE"
}

JAIL_NAME="systembase"
PKGLIST_NAME="pkglist"
LOG_RETENTION_DAYS=7

# Re-execute with lockf if not already in internal mode
if [ "$1" != "--run-internal" ]; then
  while getopts "j:p:l:" opt; do
    case "$opt" in
      j) JAIL_NAME="$OPTARG" ;;
      p) PKGLIST_NAME="$OPTARG" ;;
      l) LOG_RETENTION_DAYS="$OPTARG" ;;
    esac
  done
  LOCKFILE="/tmp/poudriere_build_${JAIL_NAME}.lock"
  exec lockf -k -t 0 "$LOCKFILE" "$0" --run-internal -j "$JAIL_NAME" -p "$PKGLIST_NAME" -l "$LOG_RETENTION_DAYS"
fi

# Internal execution starts here
check_for_update "$@"

shift
while getopts "j:p:l:" opt; do
  case "$opt" in
    j) JAIL_NAME="$OPTARG" ;;
    p) PKGLIST_NAME="$OPTARG" ;;
    l) LOG_RETENTION_DAYS="$OPTARG" ;;
  esac
done

PORTS_TREE="default"
PKGLIST="/usr/local/etc/poudriere.d/${PKGLIST_NAME}"
LOGDIR="/var/log/poudriere"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="${LOGDIR}/build-${JAIL_NAME}-${PKGLIST_NAME}-${TIMESTAMP}.log"

mkdir -p "$LOGDIR"

if [ ! -f "$PKGLIST" ]; then
  echo "[ERROR] Package list file not found: $PKGLIST"
  exit 1
fi

execute_build() {
  PIDS=$(pgrep -f "poudriere.*bulk.*-j $JAIL_NAME")
  if [ -n "$PIDS" ]; then
    echo "[WARNING] $(date) - A build is already running for jail $JAIL_NAME. PIDs: $PIDS" >> "$LOGFILE"
    echo "[WARNING] Build for $JAIL_NAME is already running. Aborting." >> "$LOGFILE"
    exit 1
  fi

  echo "[INFO] $(date) - Updating ports tree..." >> "$LOGFILE"
  /usr/local/bin/poudriere ports -u -p "$PORTS_TREE" >> "$LOGFILE" 2>&1

  echo "[INFO] $(date) - Starting package build..." >> "$LOGFILE"
  /usr/local/bin/poudriere bulk -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" >> "$LOGFILE" 2>&1
  BUILD_RESULT=$?

  if [ "$BUILD_RESULT" -eq 0 ]; then
    if grep -q "Built packages:" "$LOGFILE"; then
      echo "[INFO] $(date) - Build completed successfully. Sending report by email..." >> "$LOGFILE"
      echo "Poudriere Build OK - $JAIL_NAME - $PKGLIST_NAME - $TIMESTAMP" | mail -s "Poudriere Build OK - $JAIL_NAME" "$EMAIL_RECIPIENT" < "$LOGFILE"
    else
      echo "[INFO] $(date) - No packages were built. No email will be sent." >> "$LOGFILE"
    fi
  else
    echo "[ERROR] $(date) - Build failed. Sending error report by email..." >> "$LOGFILE"
    echo "ERROR during Poudriere Build - $JAIL_NAME - $PKGLIST_NAME - $TIMESTAMP" | mail -s "ERROR during Poudriere Build - $JAIL_NAME" "$EMAIL_RECIPIENT" < "$LOGFILE"
  fi

  echo "[INFO] $(date) - Cleaning up old packages..." >> "$LOGFILE"
  /usr/local/bin/poudriere pkgclean -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" -y >> "$LOGFILE" 2>&1

  echo "[INFO] $(date) - Removing old logs (older than $LOG_RETENTION_DAYS days)..." >> "$LOGFILE"
  find "$LOGDIR" -type f -name "build-${JAIL_NAME}-*.log" -mtime +$LOG_RETENTION_DAYS -exec rm -f {} \; >> "$LOGFILE" 2>&1

  echo "[INFO] $(date) - Script completed successfully." >> "$LOGFILE"
}

execute_build