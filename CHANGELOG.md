# Changelog

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

