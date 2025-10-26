# Changelog

All notable changes to this project are documented in this file.

## [1.1.3] - 2025-10-25 - Standalone Script: install.sh
**Add**
- Added `update_blacklist_config()` function to automatically migrate BACKUP_BLACKLIST configuration during system updates
- Integrated automatic blacklist update in `setup_configuration()` workflow (called after `add_storage_monitoring_config`)

**Fix**
- Replaced generic `/root/.*` wildcard pattern with specific exclusions to prevent unintended file exclusions
- Now automatically migrates user configurations from `/root/.*` to targeted exclusions: `/root/.npm`, `/root/.dotnet`, `/root/.local`, `/root/.gnupg`
- Implemented idempotency checks to prevent duplicate entries and allow safe multiple executions
- Preserved user custom blacklist paths during migration process
- Added timestamped backup creation before blacklist modifications (format: `backup.env.backup.YYYYMMDD_HHMMSS`)
- Improved `update_config_header()` idempotency to compare entire header block instead of hardcoded version string
- Fixed header update logic to detect any difference in header content, not just specific version numbers
- Removed trailing whitespace from HEADER_EOF to ensure consistency with REFERENCE_EOF

## [1.2.1] - 2025-10-18 - Standalone Script: security-check.sh
**Add**
- Color and text change at the end of the script for different exitcode

## [1.1.2] - 2025-10-18 - Standalone Script: install.sh
***Fix***
- Forced switching to a safe directory before cloning or copying files, preventing fatal: Unable to read current working directory errors
**Add**
- Applied chmod 744 to install.sh and new-install.sh immediately after the initial clone

## [0.3.0] - 2025-10-18 - Standalone Script: fix-permissions.sh
**Add**
- Included both installers in the routine and ensured they stay at permission level 744 during updates and repairs.

## [1.2.0] - 2025-10-18 - Standalone Script: security-check.sh
***Fix***
- Explicitly check `[ ! -f "$script" ]` before calling `stat`
- Moved hash calculation before the `if`
- Pipeline aborts by replacing `set -e` with `set -o pipefail`
- Parent-script detection to avoid false positives from `grep`
- Dependency prompt handles missing stdin in non-interactive runs
- Hash update prompt gated on TTY availability
- Kernel process scan now uses structured `ps` output without losing spacing
- Suspicious port scan normalises input and safely ignores localhost
- Unauthorized file scan now handles filenames with spaces and special characters
**Add**
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
**Add**
- The new `lock` directory survives upgrades performed with `install.sh`

## [1.1.0] - 2025-10-18 - Standalone Script: new-install.sh
**Add***
- Added full backup feature before complete removal of all files: allows creating a safety backup before the script fully deletes the files of the previous installation, in order to prevent accidental data loss.

## [0.4.2] - 2025-10-26
###/lib/backup_collect.sh
***Fix***
- Eliminated the full scan of excluded directories that previously caused major slowdowns.
###Add
- Directly prune blacklisted directories during the find traversal while preserving wildcard and single-file checks
- Automatically classify blacklist entries into directories, single files, or wildcard patterns.

## [0.4.1] - 2025-10-25
###/script/proxmox-backup.sh
***Fix***
- Fixed DEBUG log messages appearing in standard mode during bootstrap phase by implementing early argument parsing to detect -v|--verbose and -x|--extreme flags before module loading
- Modified bootstrap log level logic to respect DEBUG_LEVEL setting during pre-initialization phase instead of always using TRACE level (4)
###Add
- Added early argument parsing section (lines 135-152) to pre-detect debug flags before bootstrap logging initialization
- Added conditional log level assignment in bootstrap phase based on DEBUG_LEVEL value (standard→INFO level 2, advanced→DEBUG level 3, extreme→TRACE level 4)

### /env/backup.env
**Add**
- Added `/root/.npm` to blacklist to exclude npm cache (`_cacache`)
- Added `/root/.local` and `/root/.gnupg` to blacklist for common user directories
- Enhanced blacklist documentation with supported format examples (exact path, glob pattern, wildcard, variables)

**Fix**
- Removed generic `/root/.*` pattern to prevent unwanted exclusion of files like `/root/.config/rclone/rclone.conf`

### /lib/backup_collect.sh
**Add**
- Added support for variable expansion in blacklist paths (e.g., `${BASE_DIR}`)
- Implemented pattern matching for hidden files (e.g., `/root/.*` matches `/root/.npm`)
- Added wildcard support in blacklist patterns (e.g., `*_cacache*`)
- Maintained backward compatibility with literal path prefixes

**Fix**
- Fixed blacklist pattern matching that was only supporting exact prefix matches instead of glob patterns
- Removed duplicate wildcard matching strategy (Strategy 3) to simplify logic

### /lib/utils_counting.sh
***Fix***
- Hardened `update_prometheus_metrics` so missing files are recreated, write failures are logged, and the function always returns success.
- Wrapped metric error reporting and `count_backup_files` so `save_metric`/counting failures emit warnings, update error counters, and fall back to safe values instead of aborting.
### Add
- Added `check_fd_status` diagnostics around metrics locking in `save_metric` to verify descriptor state.

### /lib/metrics_collect.sh
***Fix***
- Fixed silent crash in collect_metrics() caused by calculate_transfer_speed() failing with set -e active when using uninitialized BACKUP_START_TIME variable (was 0, causing elapsed_time to equal current timestamp instead of seconds elapsed)
- Replaced BACKUP_START_TIME with START_TIME for backup speed calculation (righe 486-489)
**Add**
- Added trap ERR to capture and log silent failures in collect_metrics() for improved debugging (riga 16)
- Added debug logging for backup speed calculation parameters (elapsed time and size) (riga 489)
- Added debug logging for calculated backup speed result (riga 495)
- Added warning messages when fallback values are used due to calculation failures (righe 493-494)
- Added error handling with warning fallback for calculate_transfer_speed() failures (righe 493-494)
- Fixed validation of BACKUP_PRI_CREATION_TIME to prevent crash when variable contains non-numeric values (righe 597-600)

#### /lib/backup_create.sh
**Add**
- Added guard clause in count_missing_files() to safely handle unset TEMP_DIR variable and return 0 instead of crashing (righe 1346-1351)

## [0.4.0] - 2025-10-24 - Logging Enhancements
### /script/proxmox-backup.sh
**Add**
- Introduced a bootstrap log buffer in `/tmp` that captures all pre-initialisation output before `setup_logging` runs, then merges those lines into the final log once logging is active, respecting the requested verbosity (`standard`/`advanced`/`extreme`).
- Added automatic merge/cleanup logic for the bootstrap file so warning/abort paths still preserve early output.

**Fix**
- Prevented loss of startup messages when the script runs non-interactively.

### /lib/security.sh
**Add**
- Added `append_security_log_to_main`, sanitising `security-check.sh` output and appending it to the primary log with level-aware filtering (INFO/STEP always, DEBUG/TRACE only when `-v`/`-x` is used).

**Fix**
- Ensured the full security-check transcript is saved even when execution aborts (`ABORT_ON_SECURITY_ISSUES=true`), by merging the temporary log before deletion.

## [0.3.0] - 2025-10-19
### /lib/utils_counting.sh
***Fix***
- Fixed nested quote syntax errors in error description `echo` statements
- Resolved compression extension pattern matching and prevented regex injection in backup counting

### /lib/utils.sh
***Fix***
- Replaced command substitution with `if/else` in path verification traces
- Fixed decimal value formatting by removing both tilde and percent symbols from compression ratio estimates
- Removed command injection vulnerabilities from file search functions
**Add**
- Added missing function dependencies in `utils.sh` by moving formatting utilities from `metrics.sh`

### /lib/storage.sh
***Fix***
- Converted `pipefail` usage to subshell isolation in sync backup upload
**Add**
- Added `pipefail` to `upload_backup_file_async()` to detect `rclone` failures
- Added `pipefail` and progress logging to `upload_checksum_file_async()`

### /lib/security.sh
***Fix***
- Fixed `install_missing_packages` returning a false error code on successful installation
- Fixed `check_dependencies` ignoring `install_missing_packages` failure and continuing execution
**Add**
- Added a full completion check of the safety controls; if an error occurs, the script issues a crash warning.

### /lib/notify.sh
***Fix***
- Added missing `status` variable in `create_email_body`
- Telegram message encoding now correctly URL-encodes content

### /lib/metrics_collect.sh
***Fix***
- Extracted file path for calculating average age of primary logs

### /lib/metrics.sh
***Fix***
- `report_metrics_error` now increments counters
- `validate_metrics_dependencies` now correctly populates the `missing_optional` array
- Fixed divide-by-zero in `calculate_compression_ratio` for the `decimal` format
- Added missing function dependencies in `utils.sh` by moving formatting utilities from `metrics.sh`

### /lib/log.sh
***Fix***
- No more `unbound variable` error when `log.sh` is loaded with `set -u` enabled
- Removed problematic `trap`
- Removed forced initialisation of debug level
- Updated `setup_logging()`
- Updated `start_logging()`
- Protected `debug()` and `trace()` functions
- Added initialisation guard block and updated variables to use it

### /lib/core.sh
***Fix***
- Corrected debug level documentation
- Removed `set -euo pipefail`, now handled by the main script
- Some errors could result in `UNKNOWN` state; added `CRITICAL` state
- Replaced `rm -rf` with `safe_cleanup_temp_dir`
- Removed debug level variable
**Add**
- Added `safe_cleanup_temp_dir()` function with five safety guardrails

### /lib/backup_verify.sh
***Fix***
- Fixed exit code capture for `critical_errors`
- Fixed exit code capture for `sample_errors`
- Fixed portable randomisation
- Fixed `mktemp` directory usage for `rclone`

### /lib/manager.sh
***Fix***
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
***Fix***
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

