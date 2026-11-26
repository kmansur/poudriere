# Changelog

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

