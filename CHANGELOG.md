# Changelog

## [1.20.0] - 2026-11-26

### Added
- `UPDATE_PORTS_TREE=yes|no` (default `yes`): `no` skips `poudriere ports -u`; the jail is still updated.
- A `BUILD_MODE` left in an old cfg is ignored with a warning in the log (the serial mode tried on a branch was not kept).
- `MOVED_ACTION=report|fix` (default `report`): before the bulk, the package list is compared with the `MOVED` file of the ports tree (path from `poudriere ports -l`, or `PORTS_DIR`). Renamed origins (following chains and keeping `@flavor`), removed origins and renames whose target is missing are written to the log and listed in the mail; a notice mail is sent even when nothing was built. With `fix`, renamed origins are rewritten in the list (dated `.bak` backup, comments kept, an origin already listed is commented out instead of duplicated) and saved options of the old origin are copied to the new one in `options` and `*-options` directories when the new one has none. Removed origins and missing targets are only reported.
- `JAIL_NAME` (and `-j`) accept several jails separated by spaces, built one after the other in the same run under the same lock; the ports tree is updated once. `jail:pkglist` selects another list for that jail. Each jail has its own log and mail; a failing jail does not stop the next ones, but a failed ports tree update stops the run. Exit status is non-zero if any jail failed.
- All values are validated; defaults keep the 1.19.0 behaviour.

### Documentation
- INSTALL.md: `MAX_FILES=8192` (2048 broke large builds) and `TMPFS_BLACKLIST` explained (it has no effect with `USE_TMPFS="data"` and takes package names, not origins); installation from a Git checkout with a cfg table and update steps; cron for several jails; how clients trust a self-signed certificate (`PKG_ENV { SSL_CA_CERT_FILE }`) or use a public CA; section numbering and title fixed.

### Tests
- `tests/test_build.sh` covers `UPDATE_PORTS_TREE`, several jails per run, an obsolete `BUILD_MODE` in cfg and the `MOVED` report and fix.

## [1.19.0] - 2026-11-26

Release of 1.19.0-beta.2 (below) as stable. Previous release: tag v1.18.
- poudriere_build.sh: all fixes from beta.1 and beta.2; AUTOUPDATE is ignored from now on, so hosts that reach 1.19 through the 1.18 auto-updater stop updating themselves; update from a Git checkout.
- Progressive publisher (hooks, worker): still experimental and disabled by default; requires laboratory validation before use (docs/PROGRESSIVE-PUBLISH.md).

## [1.19.0-beta.2] - 2026-11-26

Script (poudriere_build.sh):
- Fix success report: search for "Built ports:" (the text Poudriere prints) only in the bulk output; "Built packages:" never matched, so success mail was never sent.
- Send error mail when jail update, ports update, bulk or pkgclean fail; report is sent at the end, after pkgclean, with summary lines and the last 100 log lines (the previous echo text was discarded by the stdin redirect).
- -h works without cfg and without mail(1); defaults apply before validation, so -j/-p work without them in cfg; validate -l and the jail, list and tree names.
- Lock per ports tree in /var/run (was per jail in /tmp): two jails sharing a tree no longer run "ports -u" under each other's bulk. A held lock is logged to syslog and exits 0 instead of producing a cron mail.
- Exact jail name match in the running-bulk check; find -delete for log retention.
- PORTS_TREE, POUDRIERE, POUDRIERE_ETC, LOGDIR and LOCKDIR may be set in cfg (used by tests).

Publisher (poudriere_publish.py):
- Accept dependencies without version (PKG_NO_VERSION_FOR_DEPS=yes, as in INSTALL.md); they match by name and origin and shared library checks still apply. Before, the native catalogue itself was rejected and nothing was ever published.
- Hash index by inode, size and mtime plus per-checksum manifest cache: unchanged packages are not read again on every run.
- Object store uses hard links to the package files (copy only across file systems), so it no longer duplicates the repository.
- Retention, enabled by default: keeps the current generation, the newest keep_generations and anything younger than min_age_hours; removes unreferenced objects, orphan manifests, stale temporary files and event queues older than event_days (never the active build).

Tests: tests/test_build.sh (mocked poudriere/mail/lockf) and 15 tests in tests/test_publish.py, including an end-to-end worker run with a fake pkg(8).

## [1.19.0-beta.1] - 2026-11-26

- Experimental opt-in progressive publisher, native hooks and isolated signed generations.
- Conservative manifest checks; no production deployment or full solver validation.
- Disable single-file auto-update in beta; stop on failed jail/ports update and skip pkgclean on bulk failure.
- Document installation, limitations, tests and rollback in docs/PROGRESSIVE-PUBLISH.md.

## [1.18] – 2025-07-08
### Added
- Automatic update of the **Poudriere jail** as the first step of the build process:
  - Added command: `/usr/local/bin/poudriere jail -u -j "$JAIL_NAME"`
  - Ensures the jail is up to date before starting the package build.

## [1.17] - 2025-06-02
### Added
- Validation for required variables: EMAIL_RECIPIENT, JAIL_NAME, and PKGLIST_NAME.
- Check for the presence of the 'mail' command before attempting to send notifications.

### Changed
- Updated script version from 1.16 to 1.17 in header.

## [1.16] - 2025-06-02
### Added
- External configuration file support via `poudriere_build.cfg`.
- Prevents overwriting user-specific configuration during auto-update.
- Fixed SCRIPT_PATH to static `/usr/local/scripts/poudriere_build.sh` for consistent self-update behavior.

