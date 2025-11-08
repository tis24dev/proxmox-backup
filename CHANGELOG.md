# Changelog

All notable changes to this project are documented in this file.

## [0.3.2] - 2025-11-08 - Filesystem check
### Standalone Script: install.sh
**Add**
- Filesystem check for change ownership

## [2.0.5] - 2025-11-06 - Error Handling & Interactive Prompt Improvements
### Standalone Script: install.sh
**Fix**
- Fixed silent script termination when commands fail in non-verbose mode
- Fixed script hanging on security-check.sh interactive prompts during installation
- Modified error handling in `install_dependencies()` to capture and display command output on failure for: apt update, apt install, apt upgrade, rclone installer, wget, tar, configure/make/make install
- Modified `create_backup()` to capture and display tar command output on failure
- Modified `clone_repository()` to capture and display git clone output on failure
- Changed stderr redirection in `run_fix_permissions()`, `run_security_check()`, and `run_first_backup()` from `>/dev/null 2>&1` to `>/dev/null` to allow interactive prompts to appear while suppressing normal output
**Add**
- Added security-check.sh dependencies to default package list: iptables, net-tools, iproute2
- Added error output capture and display for all critical commands in silent mode
- Added local variables for capturing command output: apt_output, rclone_output, build_output, wget_output, tar_output, compile_output, git_output
**Behavior**
- Silent mode now shows full error messages when commands fail instead of terminating without explanation
- Interactive prompts (dependency installation, hash updates) are now visible in silent mode, preventing installation hangs
- All required dependencies installed automatically during setup, eliminating interactive prompts during security checks

## [2.0.4] - 2025-11-05 - Cloud Connectivity Timeout Improvements
### install.sh
**Add**
- Introduced `ensure_cloud_timeout_config()` to inject the cloud timeout configuration during upgrades without overwriting user-defined values
- Updated env template

## [1.3.1] - 2025-11-05 - Cloud Connectivity Timeout Improvements
### env/backup.env
**Add**
- Added `CLOUD_CONNECTIVITY_TIMEOUT` (default 30 seconds) inside the rclone configuration block.

## [1.3.0] - 2025-11-04 - Standalone file: backup.env
**Fix**
- Removed required package list

## [2.0.3] - 2025-11-04 - Add rsync dependency
### Standalone Script: install.sh
**Add**
- Add rsync Dependency
- Dependencies installed/updated automatically
**Fix**
- Remove code duplicated in header template

## [1.0.1] - 2025-11-03 - Selective Restore with Automatic Version Detection
### script/proxmox-restore.sh
**Add**
- Implemented selective restore functionality with interactive category selection menu
- Added automatic backup version detection system using metadata files
- Added 11 new functions for selective restore capabilities
- Added automatic directory structure recreation for PVE storages and PBS datastores
- Added backup type detection and display
- Added comprehensive restore confirmation screen showing
- Implemented new restore workflow architecture
- Added metadata reading optimization
- Replaced manual `cp` operations with `rsync -a --backup --backup-dir` for safer restore operations
- Added backup of overwritten files to timestamped directory: `/tmp/current_config_backup_YYYYMMDD_HHMMSS_PID`
- Added support for uppercase PROXMOX_TYPE display using parameter expansion `${PROXMOX_TYPE^^}`
- Added validation checks using `[[ -v AVAILABLE_CATEGORIES[$cat] ]]` for compatibility with `set -o nounset`
- Added `validate_system_compatibility()` function (lines 647-709) to prevent incompatible cross-system restores
- Added dynamic menu text in `show_category_menu()` that adapts to PVE vs PBS backup type (lines 741-775)
- Added system-specific category selection logic in option 2
- Added detailed restoration plan display in `confirm_restore()` with category-specific descriptions (lines 502-567)
- Integrated compatibility validation into `prepare_restore_strategy()` workflow (lines 1175-1179)
**Fix**
- Modified main restore workflow to use new prepare/execute architecture instead of inline restore
- Fixed show_category_menu() to return exit code 1 when user cancels (option 0)
- Fixed array key existence checks to use `[[ -v array[key] ]]` instead of `[ -n "${array[key]}" ]` for set -u compatibility
- Fixed extract_backup() output to use stderr redirection (`>&2`) for status messages to avoid polluting function return value
- Fixed option 2 incorrectly mixing PVE and PBS categories (now properly separated by backup type)
- Fixed menu showing generic "STORAGE only" label for both PVE and PBS (now shows system-specific labels)
- Maintains 100% backward compatibility: legacy backups without metadata automatically use full restore mode
**Security**
- Blocks incompatible restore attempts (PVE backup → PBS system or vice versa) with detailed error messages
- Prevents system malfunction from cross-system configuration restoration
- Validates backup type matches current system before allowing restore to proceed

## [2.0.2] - 2025-11-02 - Interactive Telegram Notifications Setup
### Standalone Script: install.sh
**Add**
- Interactive prompt during installation to enable/disable Telegram notifications
- User-friendly message indicating setup "takes only a few seconds"
- Automatic configuration of `TELEGRAM_ENABLED` variable in backup.env based on user choice
- Automatic backup creation before modifying configuration file
- New function `prompt_telegram_notifications()` integrated into installation workflow after `setup_configuration()`

## [2.0.1] - 2025-11-02 - Unified Installer Architecture
### Standalone Script: install.sh (Completely Refactored)
**Fix**
- Correct function order

## [2.0.0] - 2025-10-31 - Unified Installer Architecture
### Standalone Script: install.sh (Completely Refactored)
**Add**
- Complete refactoring of install.sh into unified installer (replaces separate install.sh and new-install.sh)
- Interactive installation mode selection with automatic detection of existing installations
- Menu-driven workflow: [1] Update (preserves data) [2] Reinstall (fresh) [3] Cancel
- Flag `--reinstall` to force complete reinstallation bypassing interactive menu
- Flag `--verbose` for detailed output during installation operations
- Eliminated ~500 lines of duplicate code through consolidation
- Enhanced backup verification with file count comparison before removal
- Verification of `.git` directory existence after clone to ensure completeness
- Single code path eliminates synchronization issues between separate installers
- Conditional behavior based on `IS_UPDATE` flag for precise control flow
- Improved timing for dev branch confirmation (after user selects action)
**Fix**
- Branch existence check now uses `grep -q "refs/heads/$branch"` for reliable validation
- Prevents false positives when checking if remote branch exists
- Consistent error handling and logging across all installation scenarios
- Proper cleanup of temporary artifacts on failure or cancellation
**Behavior**
- Default mode: Detects existing installation and presents interactive menu
- With `--reinstall`: Forces complete reinstallation without interactive prompts (except REMOVE-EVERYTHING)
- With `--verbose`: Shows detailed output from apt, git, and tar operations
- Full branch selection support (main/dev) works in all modes
- Automatic preservation of user data during updates: env, config, log, backup, lock directories
**Deprecation Notice**
- `new-install.sh` is now deprecated and replaced by `install.sh --reinstall`
- The refactored `install.sh` now handles both update and reinstall scenarios
- Users calling `new-install.sh` should migrate to `install.sh --reinstall`
**Migration Path for new-install.sh users**
- Replace `new-install.sh` calls → `install.sh --reinstall`
- Branch selection unchanged: `-- dev` parameter works with all modes
- Old `install.sh` behavior (update only) → New `install.sh` default behavior (auto-detect + interactive menu)
- Old `new-install.sh` behavior (forced reinstall) → New `install.sh --reinstall` behavior

## [1.3.0] - 2025-10-31 - Installation System: Branch Selection Feature
### Standalone Script: install.sh
**Add**
- Branch selection support: add `-- dev` parameter to install development branch
- Dynamic GitHub URL generation based on selected branch
- User confirmation prompt when installing dev branch (with cancel option)
- Remote branch existence verification as first operation (before system checks/dependencies)
- Branch verification after git clone with mismatch warning
- Branch display in installation banner with dev warning
**Fix**
- Modified `git clone` to use `-b "$INSTALL_BRANCH"` flag
- Updated all hardcoded `/main/` URLs to use `${INSTALL_BRANCH}` variable

### Standalone Script: new-install.sh
**Add**
- Branch selection support with same syntax as install.sh
- User confirmation prompt when installing dev branch (with cancel option)
- Remote branch existence verification before removal to prevent data loss
- Pass branch parameter to install.sh: `bash -s -- "$INSTALL_BRANCH"`
**Fix**
- Updated usage messages to show dev branch examples

## [1.2.1] - 2025-10-28 - Standalone Script: install.sh
**Fix**
- Added lost funcion to inject email setting update

## [1.2.3] - 2025-10-31 - Standalone Script: security-check.sh
**Add**
- Added PID display in warning messages for suspicious processes by name
- Added PID and User display in warning messages for suspicious kernel processes
**Fix**
- Removed redundant final warning message "Found X potential suspicious processes!"
- Improved clarity by showing essential process information (PIDs, User) in standard mode
- Detailed process information still available via `--debug-level advanced` or `--extreme`

## [1.2.2] - 2025-10-28 - Standalone Script: security-check.sh
**Add**
- Added new secure files to the whitelist
- Added additional files to perform security checks on

## [1.2.0] - 2025-10-28 - Standalone file: backup.env
**Add**
- Added cloud email functionalities

## [1.2.0] - 2025-10-28 - Standalone Script: install.sh
**Add**
- Added log entries for env file check routine steps
**Fix**
- Modified and updated the email section in the env file during upgrade to include new required data
- Corrected initial env file template which was using an outdated version

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

---------------------------------------------------------------------------------------

## [0.7.4] - 2025-11-07 - Fix warning log
### script/security-check.sh
**Fix**
- `check_dependencies()` now incorporates the entire command `apt-get update && apt-get install -y iptables net-tools iproute2` directly into the ‘dependencies missing...’ warning, so emails/logs no longer truncate the installation instructions.
- ‘Potentially suspicious process found’ messages sanitise patterns and PIDs by replacing ‘:’ with ‘-’, preventing notification systems from truncating lines and keeping the entire details of the suspicious process visible.

## [0.7.3] - 2025-11-06 - Enhanced Secondary Backup Error Diagnostics & Datastore Directory Scan Diagnostics
### lib/storage.sh
### lib/environment.sh
**Add**
- Added `validate_backup_paths()` function (lines 465-518) to centralize path validation for all backup types
- Automatic path validation on startup: checks PRIMARY, SECONDARY, and CLOUD backup paths
- Auto-disable logic: if secondary/cloud backup is enabled but paths are not configured (empty), automatically sets `ENABLE_SECONDARY_BACKUP=false` or `ENABLE_CLOUD_BACKUP=false`
- Clear warning messages: `WARNING No secondary backup path specified` / `WARNING No secondary log path specified` / `WARNING No cloud backup path specified` / `WARNING No rclone remote specified`
- Followed by `INFO Secondary/Cloud backup is disabled` to match disabled state behavior
**Fix**
- Removed `2>/dev/null` stderr suppression from secondary directory creation (lines 404-450)
- Enhanced `setup_dirs()` to auto-disable secondary backup when parent directory missing or unwritable
- Added comprehensive mkdir error diagnostics: parent permissions, ownership, available space, mount options
- Fixed issue where empty `SECONDARY_LOG_PATH` or `CLOUD_LOG_PATH` caused cryptic `mkdir: cannot create directory '': No such file or directory` errors

### script/proxmox-backup.sh
**Add**
- Added `validate_backup_paths()` call after `setup_dirs()` (lines 490-495) to validate configuration before backup operations
- Early detection of misconfigured paths prevents failures during backup execution

### lib/storage.sh
**Fix**
- Removed `2>/dev/null` stderr suppression at lines 82-101 and 1073-1091
- Added detailed mkdir error capture and logging with real system error messages
- Enhanced diagnostics show: parent directory status, write permissions, ownership, available space, mount options
**Context**
- Resolves issue where enabled backup destinations with missing path configuration showed only generic warnings
- Transforms cryptic `mkdir: cannot create directory ''` errors into actionable `No secondary log path specified` messages
- Ensures consistent behavior: misconfigured backups are auto-disabled with clear explanation, just like when explicitly set to false

### lib/backup_collect_pbspve.sh
**Fix**
- Directory structure collection now saves `find` stderr/exit status in temp files and passa il motivo a `handle_collection_error`, così i warning mostrano subito se il problema è SIGPIPE (>20 directory), permessi o mount assente.
- Il calcolo della `disk usage` cattura l’errore di `du`, stampa `# CAUSE: …` nei metadata e, se possibile, allega l’output `df -h` per dare visibilità a mount offline o permessi mancanti.
**Behavior**
- I metadata continuano a elencare le prime 20 directory, ma quando la scansione fallisce i log sono autospeigativi e il blocco `Disk Usage` indica l’alternativa `df`.

## [0.7.2] - 2025-11-05 - Detailed Warning Output & Rclone timeout increased and editable
### lib/backup_collect.sh
**Change**
- Replace the generic warning counter with numbered `[Warning] #N …` messages that avoid `:` so the full context survives when relayed via email notifications.
- Reset the new warning/error detail counters during `reset_backup_counters()` to scope numbering to each run.
- Changed Rclone timeout mode with configurable value in backup.env

### lib/utils_counting.sh
**Fix**
- Changed Rclone timeout mode with configurable value in backup.env

### lib/notify.sh
**Fix**
- Sanitize the updated warning format when building email summaries so categories and examples keep the entire message text even without colons.
- Preserve full detail in Worker/HTML reports by splitting the hyphen-delimited message into category vs. example fields.

## [0.7.1] - 2025-11-05 - Verbose
### lib/backup_collect.sh
***Fix***
- Corrected verbose level for rsync

## [0.7.1] - 2025-11-05 - Cloud Connectivity Timeout Improvements
### lib/utils_counting.sh
**Fix**
- Ensured cloud connectivity probes honor `CLOUD_CONNECTIVITY_TIMEOUT` by using a local `cloud_timeout` variable with a 30-second fallback.

## [0.7.0] - 2025-11-03 - Selective Restore with Automatic Version Detection
### lib/backup_collect.sh
**Add**
- Added `create_backup_metadata()` function (lines 635-659) to generate backup metadata files
- Integrated metadata creation into backup workflow (line 624) - called after file collection completes
- Metadata file includes:
  - Backup version, type (PVE/PBS), timestamp, hostname
  - Feature flags: `SUPPORTS_SELECTIVE_RESTORE=true`
  - Capability list: `selective_restore,category_mapping,version_detection,auto_directory_creation`
  
### lib/security.sh
**Fix**
- Removed dependency installation and updates and moved in install.sh

### env/backup.env
**Add**
- Added `rsync` to REQUIRED_PACKAGES list (line 32) for automatic installation during dependency checks
- rsync requirement ensures selective restore functionality works on all systems
**Fix**
- Updated dependency list from `"tar gzip zstd pigz jq curl rclone gpg"` to include `rsync`

## [0.6.5] - 2025-11-03 - Metrics Module: Improved Warning Messages
### lib/metrics.sh
**Fix**
- Fixed metrics validation warnings appearing generic/empty in notification reports
- Changed message format from `"METRICS WARNING [operation]: message"` to `"message [metrics.operation]"` for compatibility with notify.sh category extraction regex
- Removed redundant summary warnings that duplicated detailed error messages:
  - Removed `"Proxmox environment validation completed with N warnings"`
  - Removed `"Metrics module initialized with environment warnings"`
- Improved validation messages with actionable suggestions:
  - Local backup path: `"Local backup path does not exist: /path (will be created automatically)"`
  - Secondary backup (parent missing): `"Secondary backup parent directory does not exist: /path - Create it with: mkdir -p /path"`
  - Secondary backup (parent exists): `"Secondary backup path does not exist: /path (will be created if parent exists)"`
- Removed auto-initialization that was causing validation to run before directories were created

### script/proxmox-backup.sh
**Fix**
- Moved metrics module initialization after directory setup to prevent false positive warnings
- Added explicit `initialize_metrics_module()` call after `setup_dirs()` (line 492)
- Metrics validation now runs after required directories are created, eliminating false warnings

## [0.6.4] - 2025-11-02 - Bug Fix: Network Filesystems
### /lib/storage.sh
**Add**
- Added `test_ownership_capability()` function to test chown support on network filesystems
- Added automatic ownership capability testing for NFS/CIFS/SMB mounts before attempting chown operations
**Fix**
- Eliminated spurious "Failed to set ownership" warnings on NFS shares with root_squash or all_squash enabled
- Improved `supports_unix_ownership()` to perform real-world chown testing on network filesystems
- Network filesystems now automatically detect server configuration (root_squash vs no_root_squash) and adapt behavior accordingly

## [0.6.3] - 2025-11-01 - Bug Fix: Smart Chunking
### /lib/backup_create.sh
**Fix**
- Removed problematic path sanitization in `perform_smart_chunking()` function (lines 955-956)
- Fixed "Failed to chunk file" error caused by asymmetric sanitization between source and destination paths
- Removed `sanitize_input()` calls for `rel_path` and `chunk_base` variables as files are already in trusted TEMP_DIR
- Improved error logging: added stderr capture from split command with detailed error output in debug mode
- Changed error handling from silent (`2>/dev/null`) to captured (`2>&1`) for better diagnostics

## [0.6.2] - 2025-11-01
### /lib/storage.sh
**Add**
- Added `supports_unix_ownership()` function to detect filesystem compatibility with Unix ownership
- Added filesystem type detection before attempting `chown` operations on backup paths
- Added informational messages for filesystems that do not support Unix ownership (FAT32, VFAT, EXFAT, NTFS)
**Fix**
- Eliminated spurious "Failed to set ownership" warnings on USB drives formatted with FAT32/EXFAT
- Improved `set_permissions()` to skip ownership changes on incompatible filesystems instead of failing
- Maintained warning behavior for legitimate ownership failures on supported filesystems (ext4, xfs, btrfs, etc.)

## [0.6.1] - 2025-10-31
###/lib/backup_collect_pbspve.sh
**Fix**
- Improved warning messages in `detect_all_datastores()` function to correctly distinguish between PBS datastores and PVE storages
- Now uses `system_types_detected` array to generate system-specific warnings
- Corrected terminology usage: "datastores" for PBS, "storages" for PVE
- Fixed PVE storage detection failing due to unsupported `--noborder` and `--output-format=json` options
- Corrected exit code check and expanded storage type support (added pbs, zfspool, rbd, cephfs)
- Improved path resolution from `/etc/pve/storage.cfg` for all storage types

## [0.5.2] - 2025-10-30
###/lib/email_relay.sh
***Add***
- Fix name process

###/lib/notify.sh
***Add***
- Fix name process

## [0.5.1] - 2025-10-28
###/script/proxmox-backup.sh
***Fix***
- Fix call list funcion

## [0.5.0] - 2025-10-28
###/script/proxmox-backup.sh
***Add***
- Added cloud email system integration

###/lib/email_relay.sh
***New***
- New file for new functionality

###/lib/notify.sh
***Add***
- Added cloud email system
- Added MAC address display in email reports

###/lib/log.sh
***Add***
- Added MAC address display
- Added display of email delivery status via cloud service

## [0.4.2] - 2025-10-26
###/lib/backup_collect.sh
***Fix***
- Eliminated the full scan of excluded directories that previously caused major slowdowns.
***Add***
- Directly prune blacklisted directories during the find traversal while preserving wildcard and single-file checks
- Automatically classify blacklist entries into directories, single files, or wildcard patterns.

## [0.4.1] - 2025-10-25
###/script/proxmox-backup.sh
***Fix***
- Fixed DEBUG log messages appearing in standard mode during bootstrap phase by implementing early argument parsing to detect -v|--verbose and -x|--extreme flags before module loading
- Modified bootstrap log level logic to respect DEBUG_LEVEL setting during pre-initialization phase instead of always using TRACE level (4)
***Add***
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

