#!/bin/sh

##############################################################################
# Script: poudriere_build.sh
# Version: 1.15a
# Author: Karim Mansur
# Description:
#   - Automates package builds using Poudriere.
#   - Supports parameters:
#       -j <jail-name>     : jail name (default: systembase)
#       -p <pkglist-name>  : package list file name (default: pkglist)
#       -l <days>          : number of days to keep logs (default: 7)
#       -h                 : show help message
#   - Optional automatic script update (can be disabled with AUTOUPDATE=no).
#   - Updates ports tree, builds packages, sends report by email, cleans up.
##############################################################################

# Configurable variables
EMAIL_RECIPIENT="monitor@domain.com.br"
AUTOUPDATE="yes"  # Set to "no" to disable script self-update
SCRIPT_URL="https://raw.githubusercontent.com/kmansur/poudriere/main/scripts/poudriere_build.sh"
SCRIPT_PATH="$(realpath "$0")"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  -j <jail>        Jail name (default: systembase)
  -p <pkglist>     Package list name (default: pkglist)
  -l <days>        Days to keep logs (default: 7)
  -h               Show this help message

Environment variables:
  AUTOUPDATE=yes|no  Enable/disable automatic script update (default: yes)
EOF
}

check_for_update() {
  [ "$AUTOUPDATE" != "yes" ] && return

  TMPFILE=$(mktemp)
  if fetch -q -o "$TMPFILE" "$SCRIPT_URL"; then
    if ! diff -q "$SCRIPT_PATH" "$TMPFILE" >/dev/null 2>&1; then
      echo "[INFO] Update detected. Updating the script..."
      cp "$TMPFILE" "$SCRIPT_PATH"
      chmod +x "$SCRIPT_PATH"
      echo "[INFO] Script updated. Restarting execution..."
      exec "$SCRIPT_PATH" "$@"
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

# Parse initial options (before lockf)
while getopts "ij:p:l:h" opt; do
  case "$opt" in
    i) ;;  # internal mode flag, just skip
    j) JAIL_NAME="$OPTARG" ;;
    p) PKGLIST_NAME="$OPTARG" ;;
    l) LOG_RETENTION_DAYS="$OPTARG" ;;
    h)
      show_help
      exit 0
      ;;
    *)
      show_help
      exit 1
      ;;
  esac
done

# Re-execute with lockf if not internal
if [ "$1" != "-i" ]; then
  LOCKFILE="/tmp/poudriere_build_${JAIL_NAME}.lock"
  exec lockf -k -t 0 "$LOCKFILE" "$0" -i -j "$JAIL_NAME" -p "$PKGLIST_NAME" -l "$LOG_RETENTION_DAYS"
fi

# Shift internal mode flag
shift

# Re-parse inside internal execution
while getopts "ij:p:l:" opt; do
  case "$opt" in
    i) ;;  # internal mode
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

check_for_update "$@"

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
  /usr/local/bin/poudriere bulk -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" -b latest >> "$LOGFILE" 2>&1
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