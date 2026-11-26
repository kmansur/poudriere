#!/bin/sh
# Version: 1.19.0-beta.2
# Tests for scripts/poudriere_build.sh with mocks of poudriere, mail and,
# when missing (non FreeBSD hosts), lockf. Nothing outside a temporary
# directory is touched. Usage: sh tests/test_build.sh

SRC="$(cd "$(dirname "$0")/.." && pwd)/scripts/poudriere_build.sh"
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
FAILURES=0

mkdir -p "$WORK/bin" "$WORK/etc" "$WORK/log" "$WORK/run" "$WORK/script"
cp "$SRC" "$WORK/script/poudriere_build.sh"
chmod 755 "$WORK/script/poudriere_build.sh"
echo "ports-mgmt/pkg" > "$WORK/etc/pkglist"

# Mock poudriere: records each call; behaviour is driven by environment.
cat > "$WORK/bin/poudriere" <<'EOF'
#!/bin/sh
echo "$*" >> "$CALLS"
case "$1" in
  jail) exit "${JAIL_RC:-0}" ;;
  ports) exit "${PORTS_RC:-0}" ;;
  bulk)
    [ "${BUILT:-0}" -eq 1 ] && echo "[00:01:00] Built ports: ports-mgmt/pkg"
    exit "${BULK_RC:-0}"
    ;;
  pkgclean) exit "${PKGCLEAN_RC:-0}" ;;
esac
EOF

# Mock mail: stores subject and body.
cat > "$WORK/bin/mail" <<'EOF'
#!/bin/sh
echo "$2" >> "$MAILS"
cat >> "$MAILS"
EOF

# Mock logger: no syslog in tests.
printf '#!/bin/sh\nexit 0\n' > "$WORK/bin/logger"

if ! command -v lockf >/dev/null 2>&1; then
  # Minimal lockf(1) stand-in: drop options and the lock file, run command.
  cat > "$WORK/bin/lockf" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -s|-k) shift ;;
    -t) shift 2 ;;
    *) break ;;
  esac
done
shift
exec "$@"
EOF
fi
chmod 755 "$WORK/bin/"*

PATH="$WORK/bin:$PATH"
CALLS="$WORK/calls"
MAILS="$WORK/mails"
export PATH CALLS MAILS

write_cfg() {
  cat > "$WORK/script/poudriere_build.cfg" <<EOF
EMAIL_RECIPIENT="test@example.invalid"
JAIL_NAME="testjail"
PKGLIST_NAME="pkglist"
POUDRIERE="$WORK/bin/poudriere"
POUDRIERE_ETC="$WORK/etc"
LOGDIR="$WORK/log"
LOCKDIR="$WORK/run"
EOF
}

run() {
  : > "$CALLS"
  : > "$MAILS"
  env "$@" "$WORK/script/poudriere_build.sh" > "$WORK/out" 2>&1
  RC=$?
}

check() {
  # check <description> <condition...>
  desc="$1"
  shift
  if "$@"; then
    echo "ok - $desc"
  else
    echo "FAIL - $desc"
    FAILURES=$((FAILURES + 1))
  fi
}

# 1. Help works without configuration.
rm -f "$WORK/script/poudriere_build.cfg"
run
check "missing cfg is an error" [ "$RC" -ne 0 ]
"$WORK/script/poudriere_build.sh" -h > "$WORK/out" 2>&1
RC=$?
check "-h without cfg exits 0" [ "$RC" -eq 0 ]
check "-h prints usage" grep -q "Usage:" "$WORK/out"

write_cfg

# 2. Successful build with packages: OK mail, pkgclean, exit 0.
run BUILT=1
check "success exits 0" [ "$RC" -eq 0 ]
check "success sends OK mail" grep -q "Poudriere Build OK - testjail" "$MAILS"
check "mail body has summary" grep -q "Built ports:" "$MAILS"
check "pkgclean runs after success" grep -q "^pkgclean" "$CALLS"

# 3. Nothing built: no mail.
run BUILT=0
check "no-op build exits 0" [ "$RC" -eq 0 ]
check "no-op build sends no mail" [ ! -s "$MAILS" ]

# 4. Bulk failure: error mail, no pkgclean, non-zero exit.
run BULK_RC=1 BUILT=1
check "bulk failure exits non-zero" [ "$RC" -ne 0 ]
check "bulk failure sends error mail" grep -q "ERROR during Poudriere Build" "$MAILS"
check "pkgclean skipped after failure" sh -c "! grep -q '^pkgclean' '$CALLS'"

# 5. Jail update failure: error mail, no bulk.
run JAIL_RC=1
check "jail update failure exits non-zero" [ "$RC" -ne 0 ]
check "jail update failure sends mail" grep -q "Jail update failed" "$MAILS"
check "no bulk after jail update failure" sh -c "! grep -q '^bulk' '$CALLS'"

# 6. Ports update failure: error mail, no bulk.
run PORTS_RC=1
check "ports update failure exits non-zero" [ "$RC" -ne 0 ]
check "ports update failure sends mail" grep -q "Ports tree update failed" "$MAILS"

# 7. pkgclean failure is reported.
run BUILT=1 PKGCLEAN_RC=1
check "pkgclean failure exits non-zero" [ "$RC" -ne 0 ]
check "pkgclean failure sends error mail" grep -q "pkgclean failed" "$MAILS"

# 8. Invalid arguments are rejected before anything runs.
: > "$CALLS"
"$WORK/script/poudriere_build.sh" -l abc > "$WORK/out" 2>&1
RC=$?
check "non-numeric -l rejected" [ "$RC" -ne 0 ]
"$WORK/script/poudriere_build.sh" -j "../x" > "$WORK/out" 2>&1
RC=$?
check "unsafe jail name rejected" [ "$RC" -ne 0 ]
check "nothing ran for invalid arguments" [ ! -s "$CALLS" ]

# 9. CLI overrides cfg.
run BUILT=1
"$WORK/script/poudriere_build.sh" -j otherjail > /dev/null 2>&1
check "-j overrides cfg" grep -q "bulk -j otherjail" "$CALLS"

if [ "$FAILURES" -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All tests passed"
