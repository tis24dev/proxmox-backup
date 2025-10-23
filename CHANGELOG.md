# Changelog

All notable changes to this project are documented in this file.

## [1.1.2] - 2025-10-18 - Standalone Script: install.sh
###Fix
- Forced switching to a safe directory before cloning or copying files, preventing fatal: Unable to read current working directory errors
###Add
- Applied chmod 744 to install.sh and new-install.sh immediately after the initial clone

## [0.3.0] - 2025-10-18 - Standalone Script: fix-permissions.sh
###Add
- Included both installers in the routine and ensured they stay at permission level 744 during updates and repairs.

## [1.2.0] - 2025-10-18 - Standalone Script: security-check.sh
### Fix
- Explicitly check `[ ! -f "$script" ]` before calling `stat`
- Moved hash calculation before the `if`
- Pipeline aborts by replacing `set -e` with `set -o pipefail`
- Parent-script detection to avoid false positives from `grep`
- Dependency prompt handles missing stdin in non-interactive runs
- Hash update prompt gated on TTY availability
- Kernel process scan now uses structured `ps` output without losing spacing
- Suspicious port scan normalises input and safely ignores localhost
- Unauthorized file scan now handles filenames with spaces and special characters
### Add
- Added `$BASE_DIR/lock` to the `dirs` array (existence check)
- Corrected debug levels
- Added `command -v netstat` check
- Added whitelist support for legitimate services in `security-check`
- Added outbound connection monitoring to `security-check`
- Modernised network tool detection with `ss` support
- Added IPv6 localhost filtering to `security-check`
- Made suspicious ports list configurable
- Hardened whitelist filtering implementation
- Associative whitelist map for suspicious port filtering

## [1.1.1] - 2025-10-18 - Standalone Script: install.sh
### Add
- The new `lock` directory survives upgrades performed with `install.sh`

## [1.1.0] - 2025-10-18 - Standalone Script: new-install.sh
****Add
- Added full backup feature before complete removal of all files: allows creating a safety backup before the script fully deletes the files of the previous installation, in order to prevent accidental data loss.

## [0.3.0] - 2025-10-19
### /lib/utils_counting.sh
**Fix bugs**
- Fixed nested quote syntax errors in error description `echo` statements
- Resolved compression extension pattern matching and prevented regex injection in backup counting

### /lib/utils.sh
**Fix bugs**
- Replaced command substitution with `if/else` in path verification traces
- Fixed decimal value formatting by removing both tilde and percent symbols from compression ratio estimates
- Removed command injection vulnerabilities from file search functions
**Add**
- Added missing function dependencies in `utils.sh` by moving formatting utilities from `metrics.sh`

### /lib/storage.sh
**Fix bugs**
- Converted `pipefail` usage to subshell isolation in sync backup upload
**Add**
- Added `pipefail` to `upload_backup_file_async()` to detect `rclone` failures
- Added `pipefail` and progress logging to `upload_checksum_file_async()`

### /lib/security.sh
**Fix bugs**
- Fixed `install_missing_packages` returning a false error code on successful installation
- Fixed `check_dependencies` ignoring `install_missing_packages` failure and continuing execution
**Add**
- Added a full completion check of the safety controls; if an error occurs, the script issues a crash warning.

### /lib/notify.sh
**Fix bugs**
- Added missing `status` variable in `create_email_body`
- Telegram message encoding now correctly URL-encodes content

### /lib/metrics_collect.sh
**Fix bugs**
- Extracted file path for calculating average age of primary logs

### /lib/metrics.sh
**Fix bugs**
- `report_metrics_error` now increments counters
- `validate_metrics_dependencies` now correctly populates the `missing_optional` array
- Fixed divide-by-zero in `calculate_compression_ratio` for the `decimal` format
- Added missing function dependencies in `utils.sh` by moving formatting utilities from `metrics.sh`

### /lib/log.sh
**Fix bugs**
- No more `unbound variable` error when `log.sh` is loaded with `set -u` enabled
- Removed problematic `trap`
- Removed forced initialisation of debug level
- Updated `setup_logging()`
- Updated `start_logging()`
- Protected `debug()` and `trace()` functions
- Added initialisation guard block and updated variables to use it

### /lib/core.sh
**Fix bugs**
- Corrected debug level documentation
- Removed `set -euo pipefail`, now handled by the main script
- Some errors could result in `UNKNOWN` state; added `CRITICAL` state
- Replaced `rm -rf` with `safe_cleanup_temp_dir`
- Removed debug level variable
**Add**
- Added `safe_cleanup_temp_dir()` function with five safety guardrails

### /lib/backup_verify.sh
**Fix bugs**
- Fixed exit code capture for `critical_errors`
- Fixed exit code capture for `sample_errors`
- Fixed portable randomisation
- Fixed `mktemp` directory usage for `rclone`

### /lib/manager.sh
**Fix bugs**
- Non-shared lock files (critical race condition)
- PIDs truncated by return (values > 255)
- Lost exit code after NOT operator
- Exit code checked by the wrong command
- `cloud_storage` lock not released in case of error

### /lib/backup_create.sh
**Fix**
- Fixed working directory corruption after `find` execution

### /lib/backup_create.sh
**Fix**
- Fixed working directory corruption after `find` execution

### /lib/backup_collect.sh.sh
**Fix**
- Wrapped `find` loops in subshells `( ... )` and removed `cd /tmp` from cleanup
**Add**
- Added marker file creation in `setup_temp_dir()`

### /lib/backup_collect_pbspve.sh
**Fix sanitize_input() - Preserve filesystem characters**
- Added helper functions: `safe_command`, `safe_mkdir`, `safe_stat_size`, `validate_output_file`
- Fixed quote escaping with apostrophes in datastore paths
- Fixed exit code tracking lost after `echo` commands
- Added data quality notes with detailed error statistics
- Improved documentation with error tracking architecture notes

### /lib/metrics.sh
- Unified lock mechanism for proper process synchronisation

### /lib/environment.sh
- Ensured lock directory creation before acquiring metrics lock
**Add**
- Added creation of `.proxmox-backup-marker` file after `mkdir TEMP_DIR`
- Added save/restore of `DEBUG_LEVEL` in `check_env_file()`

### /script/proxmox-backup.sh
**Fix**
- Safe lock cleanup with `flock` validation and orphan recovery
- Replaced `rm -rf` with `safe_cleanup_temp_dir`
- Improved script robustness with `set -e`: safer handling of dependencies and lock files
**Add**
- Added flush operation in `cleanup_handler`

## [0.2.6] - 2025-10-21
### Fixed
**Explicitly create the destination directory and use `cp -a "$source"/. "$destination"/`**
- Files changed: `lib/backup_collect.sh`

## [0.2.5] - 2025-10-19
### Fixed
**Optimise file scanning and improve safety**
- Files changed: `lib/backup_collect_pbspve.sh`

## [0.2.4] - 2025-10-19
### Fixed
**Remove duplicate system metrics collection**
- Files changed: `lib/backup_collect.sh`

