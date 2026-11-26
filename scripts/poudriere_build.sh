#!/bin/sh

##############################################################################
# Script: poudriere_build.sh
# Version: 1.19.0-beta.2
# Author: Karim Mansur
# Description:
#   - Automates package builds using Poudriere.
#   - Supports external config file poudriere_build.cfg, read from the same
#     directory as this script (not from the current directory).
#   - Beta: automatic single-file updates are deliberately disabled.
#   - Optional publication is handled by independent native hooks and worker.
#   - Parameters:
#       -j <jail-name>     : jail name (overrides config)
#       -p <pkglist-name>  : package list file name (overrides config)
#       -l <days>          : number of days to keep logs (overrides config)
#       -h                 : show help message
#   - Exit status: 0 on success, non-zero when any step failed. Cron and
#     monitoring can rely on it.
##############################################################################

# Script location; the configuration file lives next to the script.
SCRIPT_PATH="$(realpath "$0")"
CONFIG_FILE="$(dirname "$SCRIPT_PATH")/poudriere_build.cfg"

# Paths below may be overridden from the cfg file. They exist mainly so the
# script can be tested with mocks; production values are the defaults.
: "${POUDRIERE:=/usr/local/bin/poudriere}"
: "${POUDRIERE_ETC:=/usr/local/etc/poudriere.d}"
: "${LOGDIR:=/var/log/poudriere}"
: "${LOCKDIR:=/var/run}"

show_help() {
  cat <<EOF
Usage: $0 [options]

Options:
  -j <jail>        Jail name (default from config)
  -p <pkglist>     Package list name (default from config)
  -l <days>        Days to keep logs (default from config)
  -h               Show this help message

Variables (from poudriere_build.cfg):
  EMAIL_RECIPIENT         Email recipient for build reports (required)
  JAIL_NAME               Jail name (default: systembase)
  PKGLIST_NAME            Package list file name (default: pkglist)
  PORTS_TREE              Ports tree name (default: default)
  LOG_RETENTION_DAYS      Days to keep logs (default: 7)
  AUTOUPDATE              Ignored in the beta (pinned Git checkout required)
EOF
}

# Show help before any validation, so -h works without cfg or mail(1).
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
  esac
done

# Load persistent configuration if present
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
fi

# Default values (config and CLI may override them)
: "${JAIL_NAME:=systembase}"
: "${PKGLIST_NAME:=pkglist}"
: "${PORTS_TREE:=default}"
: "${LOG_RETENTION_DAYS:=7}"

# Parse options. -i is internal: it marks the run already holding the lock.
INTERNAL=0
while getopts "ij:p:l:h" opt; do
  case "$opt" in
    i) INTERNAL=1 ;;
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

# Validate values after defaults, config and CLI were all applied.
: "${EMAIL_RECIPIENT:?EMAIL_RECIPIENT is not set. Check poudriere_build.cfg}"

# Names are used in file paths and patterns; accept only safe characters.
for value in "$JAIL_NAME" "$PKGLIST_NAME" "$PORTS_TREE"; do
  case "$value" in
    ''|-*|*[!A-Za-z0-9._-]*)
      echo "[ERROR] Invalid jail, package list or ports tree name: '$value'" >&2
      exit 1
      ;;
  esac
done

case "$LOG_RETENTION_DAYS" in
  ''|*[!0-9]*)
    echo "[ERROR] Log retention must be a whole number of days: '$LOG_RETENTION_DAYS'" >&2
    exit 1
    ;;
esac

# Check if mail command is available
command -v mail >/dev/null 2>&1 || {
  echo "[ERROR] 'mail' command not found. Please install mailutils or bsd-mailx." >&2
  exit 1
}

# Locking. The lock is per ports tree, not per jail: 'ports -u' rewrites the
# tree that any bulk using it is reading, so two jails sharing one tree must
# not run at the same time. lockf exits 75 (EX_TEMPFAIL) when the lock is
# held; that is a normal condition for an hourly cron, so it is logged to
# syslog instead of producing a cron mail every hour.
if [ "$INTERNAL" -ne 1 ]; then
  LOCKFILE="${LOCKDIR}/poudriere_build_${PORTS_TREE}.lock"
  lockf -s -k -t 0 "$LOCKFILE" "$SCRIPT_PATH" -i -j "$JAIL_NAME" -p "$PKGLIST_NAME" -l "$LOG_RETENTION_DAYS"
  rc=$?
  if [ "$rc" -eq 75 ]; then
    logger -t poudriere_build "Another run holds $LOCKFILE; skipping $JAIL_NAME"
    exit 0
  fi
  exit "$rc"
fi

PKGLIST="${POUDRIERE_ETC}/${PKGLIST_NAME}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="${LOGDIR}/build-${JAIL_NAME}-${PKGLIST_NAME}-${TIMESTAMP}.log"

mkdir -p "$LOGDIR" || exit 1

log() {
  echo "$1 $(date) - $2" >> "$LOGFILE"
}

# Send a short report: summary lines from the bulk plus the end of the log.
# Arguments: subject, status text. The full log stays in $LOGFILE.
notify() {
  body=$(mktemp) || return 1
  {
    echo "$2"
    echo "Jail: $JAIL_NAME  List: $PKGLIST_NAME  Tree: $PORTS_TREE  Run: $TIMESTAMP"
    echo "Full log: $LOGFILE"
    echo
    grep -E "(Built|Failed|Skipped|Ignored|Fetched) ports:" "$LOGFILE"
    echo
    echo "---- last 100 log lines ----"
    tail -n 100 "$LOGFILE"
  } > "$body"
  if mail -s "$1" "$EMAIL_RECIPIENT" < "$body"; then
    log "[INFO]" "Report sent: $1"
  else
    log "[ERROR]" "mail(1) failed to send: $1"
  fi
  rm -f "$body"
}

if [ ! -f "$PKGLIST" ]; then
  log "[ERROR]" "Package list file not found: $PKGLIST"
  notify "ERROR during Poudriere Build - $JAIL_NAME" "Package list file not found: $PKGLIST"
  exit 1
fi

if [ "${AUTOUPDATE:-no}" = "yes" ]; then
  # Never replace a multi-file beta with the single-file stable updater.
  log "[WARNING]" "Beta requires a pinned Git checkout; AUTOUPDATE ignored."
fi

execute_build() {
  # Match the exact jail name, not a prefix (jail "14" must not match "142").
  PIDS=$(pgrep -f "poudriere.*bulk.*-j ${JAIL_NAME}( |\$)")
  if [ -n "$PIDS" ]; then
    log "[WARNING]" "A build is already running for jail $JAIL_NAME. PIDs: $PIDS. Aborting."
    return 1
  fi

  log "[INFO]" "Updating jail $JAIL_NAME..."
  if ! "$POUDRIERE" jail -u -j "$JAIL_NAME" >> "$LOGFILE" 2>&1; then
    log "[ERROR]" "Jail update failed; build not started."
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Jail update failed; build not started."
    return 1
  fi

  log "[INFO]" "Updating ports tree $PORTS_TREE..."
  if ! "$POUDRIERE" ports -u -p "$PORTS_TREE" >> "$LOGFILE" 2>&1; then
    log "[ERROR]" "Ports update failed; build not started."
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Ports tree update failed; build not started."
    return 1
  fi

  log "[INFO]" "Starting package build..."
  # Remember where the bulk output starts so only it is searched later.
  BULK_START=$(($(wc -l < "$LOGFILE") + 1))
  "$POUDRIERE" bulk -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" -b latest >> "$LOGFILE" 2>&1
  BUILD_RESULT=$?
  STATUS=$BUILD_RESULT

  # Poudriere prints "Built ports: ..." when at least one port was built.
  BUILT=0
  if tail -n "+$BULK_START" "$LOGFILE" | grep -q "Built ports:"; then
    BUILT=1
  fi

  # Do not delete packages after an unsuccessful bulk.
  if [ "$BUILD_RESULT" -eq 0 ]; then
    log "[INFO]" "Cleaning up old packages..."
    if ! "$POUDRIERE" pkgclean -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" -y >> "$LOGFILE" 2>&1; then
      log "[ERROR]" "pkgclean failed."
      STATUS=1
    fi
  else
    log "[WARNING]" "Bulk returned $BUILD_RESULT; pkgclean skipped."
  fi

  log "[INFO]" "Removing script logs older than $LOG_RETENTION_DAYS days..."
  find "$LOGDIR" -type f -name "build-${JAIL_NAME}-*.log" -mtime "+$LOG_RETENTION_DAYS" -delete >> "$LOGFILE" 2>&1

  log "[INFO]" "Script finished: bulk status $BUILD_RESULT, overall status $STATUS."

  if [ "$BUILD_RESULT" -ne 0 ]; then
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Bulk failed with status $BUILD_RESULT."
  elif [ "$STATUS" -ne 0 ]; then
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Bulk succeeded but pkgclean failed."
  elif [ "$BUILT" -eq 1 ]; then
    notify "Poudriere Build OK - $JAIL_NAME" "Build completed successfully."
  else
    log "[INFO]" "No packages were built. No email will be sent."
  fi

  return "$STATUS"
}

execute_build
