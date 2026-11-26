#!/bin/sh

##############################################################################
# Script: poudriere_build.sh
# Version: 1.20.0
# Author: Karim Mansur
# Description:
#   - Automates package builds using Poudriere.
#   - Supports external config file poudriere_build.cfg, read from the same
#     directory as this script (not from the current directory).
#   - Since 1.19 automatic single-file updates are disabled; update from a
#     pinned Git checkout instead.
#   - Optional (experimental) progressive publication is handled by
#     independent native hooks and worker.
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
  UPDATE_PORTS_TREE       yes|no: run 'poudriere ports -u' before building
                          (default: yes)
  BUILD_MODE              bulk|serial (default: bulk)
                            bulk   : one bulk with the whole list
                            serial : one bulk per origin of the list; the
                                     repository is committed after each one
  MOVED_ACTION            report|fix (default: report)
                            report : list origins of the package list that
                                     the ports tree MOVED file renamed or
                                     removed, in the log and the mail
                            fix    : also rewrite renamed origins in the
                                     list (dated backup kept) and copy saved
                                     options to the new origin
  PORTS_DIR               Ports tree path (default: from 'poudriere ports -l')
  LOG_RETENTION_DAYS      Days to keep logs (default: 7)
  AUTOUPDATE              Ignored since 1.19 (update from a Git checkout)
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
: "${UPDATE_PORTS_TREE:=yes}"
: "${BUILD_MODE:=bulk}"
: "${MOVED_ACTION:=report}"

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

case "$UPDATE_PORTS_TREE" in
  yes|no) ;;
  *)
    echo "[ERROR] UPDATE_PORTS_TREE must be yes or no: '$UPDATE_PORTS_TREE'" >&2
    exit 1
    ;;
esac

case "$BUILD_MODE" in
  bulk|serial) ;;
  *)
    echo "[ERROR] BUILD_MODE must be bulk or serial: '$BUILD_MODE'" >&2
    exit 1
    ;;
esac

case "$MOVED_ACTION" in
  report|fix) ;;
  *)
    echo "[ERROR] MOVED_ACTION must be report or fix: '$MOVED_ACTION'" >&2
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
    if [ -s "$MOVED_REPORT" ]; then
      echo "---- package list: moved or removed origins ----"
      cat "$MOVED_REPORT"
      echo
    fi
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

# Report of moved/removed origins for this run (see check_moved).
MOVED_REPORT=$(mktemp) || exit 1
trap 'rm -f "$MOVED_REPORT"' EXIT

if [ ! -f "$PKGLIST" ]; then
  log "[ERROR]" "Package list file not found: $PKGLIST"
  notify "ERROR during Poudriere Build - $JAIL_NAME" "Package list file not found: $PKGLIST"
  exit 1
fi

if [ "${AUTOUPDATE:-no}" = "yes" ]; then
  # The single-file updater cannot update a multi-file release.
  log "[WARNING]" "AUTOUPDATE is ignored since 1.19; update from a Git checkout."
fi

# Serial mode: one bulk per origin, in list order. Each bulk commits the
# repository (and runs the pkgrepo hooks), so every finished port is
# published without waiting for the whole list. A failure does not stop
# the remaining origins; the run fails at the end and lists them.
# Blank lines and '#' comments in the list are ignored.
run_serial() {
  total=$(grep -cvE '^[[:space:]]*(#|$)' "$PKGLIST")
  count=0
  failures=0
  # Read the list on descriptor 3 so poudriere cannot consume it from stdin.
  while IFS= read -r line <&3 || [ -n "$line" ]; do
    origin=$(echo "$line" | sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$origin" ] || continue
    count=$((count + 1))
    log "[INFO]" "Serial build $count/$total: $origin"
    if ! "$POUDRIERE" bulk -j "$JAIL_NAME" -p "$PORTS_TREE" -b latest "$origin" >> "$LOGFILE" 2>&1 </dev/null; then
      log "[ERROR]" "Bulk failed for $origin"
      FAILED_ORIGINS="$FAILED_ORIGINS $origin"
      failures=$((failures + 1))
    fi
  done 3< "$PKGLIST"
  log "[INFO]" "Serial build finished: $count origins, $failures failed."
  [ "$failures" -eq 0 ]
}

# Path of the ports tree: PORTS_DIR from cfg, else the last column of
# 'poudriere ports -l -q' for PORTS_TREE (the timestamp column has spaces).
ports_dir() {
  if [ -n "${PORTS_DIR:-}" ]; then
    echo "$PORTS_DIR"
    return
  fi
  "$POUDRIERE" ports -l -q 2>/dev/null | awk -v t="$PORTS_TREE" '$1 == t { print $NF; exit }'
}

# Compare the package list with the MOVED file of the ports tree.
# MOVED lines are "old|new|date|reason"; an empty "new" means the port was
# removed. Renames are followed in chains (a -> b -> c). Flavors (@name)
# are kept. Writes one line per affected origin to $MOVED_REPORT and, with
# MOVED_ACTION=fix, rewrites renamed origins in the list.
check_moved() {
  tree=$(ports_dir)
  moved="$tree/MOVED"
  if [ -z "$tree" ] || [ ! -r "$moved" ]; then
    log "[WARNING]" "MOVED file not found for ports tree $PORTS_TREE (${moved}); check skipped."
    return 0
  fi

  pairs=$(mktemp) || return 1
  # Output: kind|old|new|date|reason (kind: MOVED, REMOVED or MISSING when
  # the new origin does not exist in the tree).
  awk -F'|' -v tree="$tree" '
    FNR == NR {
      if ($0 ~ /^#/ || NF < 2) next
      to[$1] = $2; when[$1] = $3; why[$1] = $4
      next
    }
    {
      line = $0
      sub(/#.*/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      if (line == "") next
      origin = line; flavor = ""
      at = index(origin, "@")
      if (at) { flavor = substr(origin, at); origin = substr(origin, 1, at - 1) }
      if (!(origin in to) || seen[line]++) next
      cur = origin; hops = 0; kind = "MOVED"
      while ((cur in to) && hops < 20) {
        last = cur
        if (to[cur] == "") { kind = "REMOVED"; break }
        cur = to[cur]; hops++
      }
      new = (kind == "REMOVED") ? "" : cur flavor
      if (kind == "MOVED" && system("test -d \"" tree "/" cur "\"") != 0) kind = "MISSING"
      print kind "|" line "|" new "|" when[last] "|" why[last]
    }
  ' "$moved" "$PKGLIST" > "$pairs"

  if [ ! -s "$pairs" ]; then
    rm -f "$pairs"
    return 0
  fi

  while IFS='|' read -r kind old new when why; do
    case "$kind" in
      MOVED) echo "renamed: $old -> $new ($when: $why)" ;;
      REMOVED) echo "removed: $old ($when: $why) - remove it from the list" ;;
      MISSING) echo "renamed: $old -> $new ($when), but $new is not in the tree - check by hand" ;;
    esac
  done < "$pairs" >> "$MOVED_REPORT"
  log "[WARNING]" "Package list has moved or removed origins:"
  sed 's/^/    /' "$MOVED_REPORT" >> "$LOGFILE"

  if [ "$MOVED_ACTION" = "fix" ] && grep -q '^MOVED|' "$pairs"; then
    fix_moved "$pairs"
  fi
  rm -f "$pairs"
  return 0
}

# Rewrite renamed origins in the package list. The original is kept as
# <list>.<timestamp>.bak with permissions. Comments and spacing are kept; a
# line whose new origin is already in the list is commented out instead of
# duplicated. Saved options of the old origin are copied to the new one in
# every options directory of POUDRIERE_ETC, only when the new one has none.
fix_moved() {
  backup="${PKGLIST}.${TIMESTAMP}.bak"
  new_list=$(mktemp) || return 1
  if ! cp -p "$PKGLIST" "$backup"; then
    log "[ERROR]" "Could not back up $PKGLIST; package list not changed."
    rm -f "$new_list"
    return 1
  fi
  # First file: kind|old|new|... pairs; second file: the package list.
  awk -F'|' '
    FNR == NR { if ($1 == "MOVED") to[$2] = $3; next }
    { lines[++n] = $0 }
    END {
      # Origins present in the list, to avoid duplicates after renaming.
      for (i = 1; i <= n; i++) {
        o = lines[i]; sub(/#.*/, "", o); gsub(/^[ \t]+|[ \t]+$/, "", o)
        if (o != "") present[o] = 1
      }
      for (i = 1; i <= n; i++) {
        o = lines[i]; sub(/#.*/, "", o); gsub(/^[ \t]+|[ \t]+$/, "", o)
        if (o != "" && (o in to)) {
          if (to[o] in present) {
            print "# MOVED to " to[o] " (already listed): " lines[i]
          } else {
            line = lines[i]
            p = index(line, o)
            print substr(line, 1, p - 1) to[o] substr(line, p + length(o))
            present[to[o]] = 1
          }
        } else {
          print lines[i]
        }
      }
    }
  ' "$1" "$PKGLIST" > "$new_list"
  # Write through the existing file to keep its owner and mode.
  cat "$new_list" > "$PKGLIST"
  rm -f "$new_list"
  log "[INFO]" "Package list updated; backup: $backup"
  echo "package list updated (MOVED_ACTION=fix); backup: $backup" >> "$MOVED_REPORT"

  grep '^MOVED|' "$1" | while IFS='|' read -r kind old new when why; do
    old_dir=$(echo "${old%@*}" | tr / _)
    new_dir=$(echo "${new%@*}" | tr / _)
    for optdir in "$POUDRIERE_ETC"/options "$POUDRIERE_ETC"/*-options; do
      [ -d "$optdir/$old_dir" ] || continue
      if [ -e "$optdir/$new_dir" ]; then
        echo "options: $optdir/$new_dir already exists; $old_dir not copied" >> "$MOVED_REPORT"
      elif cp -Rp "$optdir/$old_dir" "$optdir/$new_dir"; then
        echo "options: copied $optdir/$old_dir -> $new_dir" >> "$MOVED_REPORT"
      fi
    done
  done
  return 0
}

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

  if [ "$UPDATE_PORTS_TREE" = "yes" ]; then
    log "[INFO]" "Updating ports tree $PORTS_TREE..."
    if ! "$POUDRIERE" ports -u -p "$PORTS_TREE" >> "$LOGFILE" 2>&1; then
      log "[ERROR]" "Ports update failed; build not started."
      notify "ERROR during Poudriere Build - $JAIL_NAME" "Ports tree update failed; build not started."
      return 1
    fi
  else
    log "[INFO]" "UPDATE_PORTS_TREE=no; keeping ports tree $PORTS_TREE as is."
  fi

  check_moved

  # Remember where the bulk output starts so only it is searched later.
  BULK_START=$(($(wc -l < "$LOGFILE") + 1))
  FAILED_ORIGINS=""
  if [ "$BUILD_MODE" = "serial" ]; then
    run_serial
    BUILD_RESULT=$?
  else
    log "[INFO]" "Starting package build (one bulk for the whole list)..."
    "$POUDRIERE" bulk -j "$JAIL_NAME" -p "$PORTS_TREE" -f "$PKGLIST" -b latest >> "$LOGFILE" 2>&1
    BUILD_RESULT=$?
  fi
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

  if [ "$BUILD_RESULT" -ne 0 ] && [ -n "$FAILED_ORIGINS" ]; then
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Serial build: bulk failed for:$FAILED_ORIGINS"
  elif [ "$BUILD_RESULT" -ne 0 ]; then
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Bulk failed with status $BUILD_RESULT."
  elif [ "$STATUS" -ne 0 ]; then
    notify "ERROR during Poudriere Build - $JAIL_NAME" "Bulk succeeded but pkgclean failed."
  elif [ "$BUILT" -eq 1 ]; then
    notify "Poudriere Build OK - $JAIL_NAME" "Build completed successfully."
  else
    if [ -s "$MOVED_REPORT" ]; then
      notify "Poudriere Build - $JAIL_NAME - package list needs attention" "No packages were built, but the package list has moved or removed origins."
    else
      log "[INFO]" "No packages were built. No email will be sent."
    fi
  fi

  return "$STATUS"
}

execute_build
