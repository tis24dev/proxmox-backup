package orchestrator

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/tis24dev/proxmox-backup/internal/config"
	"github.com/tis24dev/proxmox-backup/internal/logging"
)

var ErrRestoreAborted = errors.New("restore workflow aborted by user")

func RunRestoreWorkflow(ctx context.Context, cfg *config.Config, logger *logging.Logger, version string) error {
	if cfg == nil {
		return fmt.Errorf("configuration not available")
	}

	reader := bufio.NewReader(os.Stdin)
	candidate, prepared, err := prepareDecryptedBackup(ctx, reader, cfg, logger, version)
	if err != nil {
		return err
	}
	defer prepared.Cleanup()

	destRoot := "/"
	logger.Info("Restore target: system root (/) — files will be written back to their original paths")

	// Detect system type
	systemType := DetectCurrentSystem()
	logger.Info("Detected system type: %s", GetSystemTypeString(systemType))

	// Validate compatibility
	if err := ValidateCompatibility(candidate.Manifest); err != nil {
		logger.Warning("Compatibility check: %v", err)
		fmt.Println()
		fmt.Printf("⚠ %v\n", err)
		fmt.Println()
		fmt.Print("Do you want to continue anyway? This may cause system instability. (yes/no): ")

		response, _ := reader.ReadString('\n')
		if strings.TrimSpace(strings.ToLower(response)) != "yes" {
			return fmt.Errorf("restore aborted due to incompatibility")
		}
	}

	// Analyze available categories in the backup
	logger.Info("Analyzing backup contents...")
	availableCategories, err := AnalyzeBackupCategories(prepared.ArchivePath, logger)
	if err != nil {
		logger.Warning("Could not analyze categories: %v", err)
		logger.Info("Falling back to full restore mode")
		return runFullRestore(ctx, reader, candidate, prepared, destRoot, logger)
	}

	// Show restore mode selection menu
	mode, err := ShowRestoreModeMenu(logger, systemType)
	if err != nil {
		if err.Error() == "user cancelled" {
			return ErrRestoreAborted
		}
		return err
	}

	// Determine selected categories based on mode
	var selectedCategories []Category
	if mode == RestoreModeCustom {
		// Interactive category selection
		selectedCategories, err = ShowCategorySelectionMenu(logger, availableCategories, systemType)
		if err != nil {
			if err.Error() == "user cancelled" {
				return ErrRestoreAborted
			}
			return err
		}
	} else {
		// Pre-defined mode (Full, Storage, Base)
		selectedCategories = GetCategoriesForMode(mode, systemType, availableCategories)
	}

	// Create restore configuration
	restoreConfig := &SelectiveRestoreConfig{
		Mode:               mode,
		SelectedCategories: selectedCategories,
		SystemType:         systemType,
		Metadata:           candidate.Manifest,
	}

	// Show detailed restore plan
	ShowRestorePlan(logger, restoreConfig)

	// Confirm operation
	confirmed, err := ConfirmRestoreOperation(logger)
	if err != nil {
		return err
	}
	if !confirmed {
		logger.Info("Restore operation cancelled by user")
		return ErrRestoreAborted
	}

	// Create safety backup of current configuration
	logger.Info("")
	safetyBackup, err := CreateSafetyBackup(logger, selectedCategories, destRoot)
	if err != nil {
		logger.Warning("Failed to create safety backup: %v", err)
		fmt.Println()
		fmt.Print("Continue without safety backup? (yes/no): ")
		response, _ := reader.ReadString('\n')
		if strings.TrimSpace(strings.ToLower(response)) != "yes" {
			return fmt.Errorf("restore aborted: safety backup failed")
		}
	} else {
		logger.Info("Safety backup location: %s", safetyBackup.BackupPath)
		logger.Info("You can restore from this backup if needed using: tar -xzf %s -C /", safetyBackup.BackupPath)
	}

	// Perform selective extraction
	logger.Info("")
	detailedLogPath, err := extractSelectiveArchive(ctx, prepared.ArchivePath, destRoot, selectedCategories, mode, logger)
	if err != nil {
		logger.Error("Restore failed: %v", err)
		if safetyBackup != nil {
			logger.Info("You can rollback using the safety backup at: %s", safetyBackup.BackupPath)
		}
		return err
	}

	// Recreate directory structures from configuration files if relevant categories were restored
	logger.Info("")
	if shouldRecreateDirectories(systemType, selectedCategories) {
		if err := RecreateDirectoriesFromConfig(systemType, logger); err != nil {
			logger.Warning("Failed to recreate directory structures: %v", err)
			logger.Warning("You may need to manually create storage/datastore directories")
		}
	} else {
		logger.Debug("Skipping datastore/storage directory recreation (category not selected)")
	}

	logger.Info("")
	logger.Info("Restore completed successfully.")
	logger.Info("Temporary decrypted bundle removed.")

	if detailedLogPath != "" {
		logger.Info("Detailed restore log: %s", detailedLogPath)
	}

	if safetyBackup != nil {
		logger.Info("Safety backup preserved at: %s", safetyBackup.BackupPath)
		logger.Info("Remove it manually if restore was successful: rm %s", safetyBackup.BackupPath)
	}

	logger.Info("")
	logger.Info("IMPORTANT: You may need to restart services for changes to take effect.")
	if systemType == SystemTypePVE {
		logger.Info("  PVE services: systemctl restart pve-cluster pvedaemon pveproxy")
	} else if systemType == SystemTypePBS {
		logger.Info("  PBS services: systemctl restart proxmox-backup-proxy proxmox-backup")

		// Check ZFS pool status for PBS systems only when ZFS category was restored
		if hasCategoryID(selectedCategories, "zfs") {
			logger.Info("")
			if err := checkZFSPoolsAfterRestore(logger); err != nil {
				logger.Warning("ZFS pool check: %v", err)
			}
		} else {
			logger.Debug("Skipping ZFS pool verification (ZFS category not selected)")
		}
	}

	return nil
}

// checkZFSPoolsAfterRestore checks if ZFS pools need to be imported after restore
func checkZFSPoolsAfterRestore(logger *logging.Logger) error {
	if _, err := exec.LookPath("zpool"); err != nil {
		// zpool utility not available -> no ZFS tooling installed
		return nil
	}

	logger.Info("Checking ZFS pool status...")

	configuredPools := detectConfiguredZFSPools()
	importablePools, importOutput, importErr := detectImportableZFSPools()

	if len(configuredPools) > 0 {
		logger.Warning("Found %d ZFS pool(s) configured for automatic import:", len(configuredPools))
		for _, pool := range configuredPools {
			logger.Warning("  - %s", pool)
		}
		logger.Info("")
	}

	if importErr != nil {
		logger.Warning("`zpool import` command returned an error: %v", importErr)
		if strings.TrimSpace(importOutput) != "" {
			logger.Warning("`zpool import` output:\n%s", importOutput)
		}
	} else if len(importablePools) > 0 {
		logger.Warning("`zpool import` reports pools waiting to be imported:")
		for _, pool := range importablePools {
			logger.Warning("  - %s", pool)
		}
		logger.Info("")
	}

	if len(importablePools) == 0 {
		logger.Info("`zpool import` did not report pools waiting for import.")

		if len(configuredPools) > 0 {
			logger.Info("")
			for _, pool := range configuredPools {
				if err := exec.Command("zpool", "status", pool).Run(); err == nil {
					logger.Info("Pool %s is already imported (no manual action needed)", pool)
				} else {
					logger.Warning("Systemd expects pool %s, but `zpool import` and `zpool status` did not report it. Check disk visibility and pool status.", pool)
				}
			}
		}
		return nil
	}

	logger.Info("⚠ IMPORTANT: ZFS pools may need manual import after restore!")
	logger.Info("  Before rebooting, run these commands:")
	logger.Info("  1. Check available pools:  zpool import")
	for _, pool := range importablePools {
		logger.Info("  2. Import pool manually:   zpool import %s", pool)
	}
	logger.Info("  3. Verify pool status:     zpool status")
	logger.Info("")
	logger.Info("  If pools fail to import, check:")
	logger.Info("  - journalctl -u zfs-import@<pool-name>.service oppure import@<pool-name>.service")
	logger.Info("  - zpool import -d /dev/disk/by-id")
	logger.Info("")

	return nil
}

func detectConfiguredZFSPools() []string {
	pools := make(map[string]struct{})

	directories := []string{
		"/etc/systemd/system/zfs-import.target.wants",
		"/etc/systemd/system/multi-user.target.wants",
	}

	for _, dir := range directories {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}

		for _, entry := range entries {
			if pool := parsePoolNameFromUnit(entry.Name()); pool != "" {
				pools[pool] = struct{}{}
			}
		}
	}

	globPatterns := []string{
		"/etc/systemd/system/zfs-import@*.service",
		"/etc/systemd/system/import@*.service",
	}

	for _, pattern := range globPatterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			continue
		}
		for _, match := range matches {
			if pool := parsePoolNameFromUnit(filepath.Base(match)); pool != "" {
				pools[pool] = struct{}{}
			}
		}
	}

	var poolNames []string
	for pool := range pools {
		poolNames = append(poolNames, pool)
	}
	sort.Strings(poolNames)
	return poolNames
}

func parsePoolNameFromUnit(unitName string) string {
	switch {
	case strings.HasPrefix(unitName, "zfs-import@") && strings.HasSuffix(unitName, ".service"):
		pool := strings.TrimPrefix(unitName, "zfs-import@")
		return strings.TrimSuffix(pool, ".service")
	case strings.HasPrefix(unitName, "import@") && strings.HasSuffix(unitName, ".service"):
		pool := strings.TrimPrefix(unitName, "import@")
		return strings.TrimSuffix(pool, ".service")
	default:
		return ""
	}
}

func detectImportableZFSPools() ([]string, string, error) {
	var output bytes.Buffer

	cmd := exec.Command("zpool", "import")
	cmd.Stdout = &output
	cmd.Stderr = &output

	err := cmd.Run()
	poolNames := parseZpoolImportOutput(output.String())

	if err != nil {
		return poolNames, output.String(), err
	}
	return poolNames, output.String(), nil
}

func parseZpoolImportOutput(output string) []string {
	var pools []string
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if strings.HasPrefix(strings.ToLower(line), "pool:") {
			pool := strings.TrimSpace(line[len("pool:"):])
			if pool != "" {
				pools = append(pools, pool)
			}
		}
	}
	return pools
}

func combinePoolNames(a, b []string) []string {
	merged := make(map[string]struct{})
	for _, pool := range a {
		merged[pool] = struct{}{}
	}
	for _, pool := range b {
		merged[pool] = struct{}{}
	}

	if len(merged) == 0 {
		return nil
	}

	names := make([]string, 0, len(merged))
	for pool := range merged {
		names = append(names, pool)
	}
	sort.Strings(names)
	return names
}

func shouldRecreateDirectories(systemType SystemType, categories []Category) bool {
	switch systemType {
	case SystemTypePVE:
		return hasCategoryID(categories, "storage_pve")
	case SystemTypePBS:
		return hasCategoryID(categories, "datastore_pbs")
	default:
		return false
	}
}

func hasCategoryID(categories []Category, id string) bool {
	for _, cat := range categories {
		if cat.ID == id {
			return true
		}
	}
	return false
}

// runFullRestore performs a full restore without selective options (fallback)
func runFullRestore(ctx context.Context, reader *bufio.Reader, candidate *decryptCandidate, prepared *preparedBundle, destRoot string, logger *logging.Logger) error {
	if err := confirmRestoreAction(ctx, reader, candidate, destRoot); err != nil {
		return err
	}

	if err := extractPlainArchive(ctx, prepared.ArchivePath, destRoot, logger); err != nil {
		return err
	}

	logger.Info("Restore completed successfully.")
	return nil
}

func confirmRestoreAction(ctx context.Context, reader *bufio.Reader, cand *decryptCandidate, dest string) error {
	manifest := cand.Manifest
	fmt.Println()
	fmt.Printf("Selected backup: %s (%s)\n", cand.DisplayBase, manifest.CreatedAt.Format("2006-01-02 15:04:05"))
	fmt.Println("Restore destination: / (system root; original paths will be preserved)")
	fmt.Println("WARNING: This operation will overwrite configuration files on this system.")
	fmt.Println("Type RESTORE to proceed or 0 to cancel.")

	for {
		fmt.Print("Confirmation: ")
		input, err := readLineWithContext(ctx, reader)
		if err != nil {
			return err
		}
		switch strings.TrimSpace(input) {
		case "RESTORE":
			return nil
		case "0":
			return ErrRestoreAborted
		default:
			fmt.Println("Please type RESTORE to confirm or 0 to cancel.")
		}
	}
}

func extractPlainArchive(ctx context.Context, archivePath, destRoot string, logger *logging.Logger) error {
	if err := os.MkdirAll(destRoot, 0o755); err != nil {
		return fmt.Errorf("create destination directory: %w", err)
	}

	if destRoot == "/" && os.Geteuid() != 0 {
		return fmt.Errorf("restore to %s requires root privileges", destRoot)
	}

	logger.Info("Extracting archive %s into %s", filepath.Base(archivePath), destRoot)

	// Use native Go extraction to preserve atime/ctime from PAX headers
	if err := extractArchiveNative(ctx, archivePath, destRoot, logger, nil, RestoreModeFull, nil, ""); err != nil {
		return fmt.Errorf("archive extraction failed: %w", err)
	}

	return nil
}

// extractSelectiveArchive extracts only files matching selected categories
func extractSelectiveArchive(ctx context.Context, archivePath, destRoot string, categories []Category, mode RestoreMode, logger *logging.Logger) (string, error) {
	if err := os.MkdirAll(destRoot, 0o755); err != nil {
		return "", fmt.Errorf("create destination directory: %w", err)
	}

	if destRoot == "/" && os.Geteuid() != 0 {
		return "", fmt.Errorf("restore to %s requires root privileges", destRoot)
	}

	// Create detailed log directory
	logDir := "/tmp/proxmox-backup"
	if err := os.MkdirAll(logDir, 0755); err != nil {
		logger.Warning("Could not create log directory: %v", err)
	}

	// Create detailed log file
	timestamp := time.Now().Format("20060102_150405")
	logPath := filepath.Join(logDir, fmt.Sprintf("restore_%s.log", timestamp))
	logFile, err := os.Create(logPath)
	if err != nil {
		logger.Warning("Could not create detailed log file: %v", err)
		logFile = nil
	} else {
		defer logFile.Close()
		logger.Info("Detailed restore log: %s", logPath)
	}

	logger.Info("Extracting selected categories from archive %s into %s", filepath.Base(archivePath), destRoot)

	// Use native Go extraction with category filter
	if err := extractArchiveNative(ctx, archivePath, destRoot, logger, categories, mode, logFile, logPath); err != nil {
		return logPath, err
	}

	return logPath, nil
}

// extractArchiveNative extracts TAR archives natively in Go, preserving all timestamps
// If categories is nil, all files are extracted. Otherwise, only files matching the categories are extracted.
func extractArchiveNative(ctx context.Context, archivePath, destRoot string, logger *logging.Logger, categories []Category, mode RestoreMode, logFile *os.File, logFilePath string) error {
	// Open the archive file
	file, err := os.Open(archivePath)
	if err != nil {
		return fmt.Errorf("open archive: %w", err)
	}
	defer file.Close()

	// Create decompression reader based on file extension
	reader, err := createDecompressionReader(file, archivePath)
	if err != nil {
		return fmt.Errorf("create decompression reader: %w", err)
	}
	if closer, ok := reader.(io.Closer); ok {
		defer closer.Close()
	}

	// Create TAR reader
	tarReader := tar.NewReader(reader)

	// Write log header if log file is available
	if logFile != nil {
		fmt.Fprintf(logFile, "=== PROXMOX RESTORE LOG ===\n")
		fmt.Fprintf(logFile, "Date: %s\n", time.Now().Format("2006-01-02 15:04:05"))
		fmt.Fprintf(logFile, "Mode: %s\n", getModeName(mode))
		if categories != nil && len(categories) > 0 {
			fmt.Fprintf(logFile, "Selected categories: %d categories\n", len(categories))
			for _, cat := range categories {
				fmt.Fprintf(logFile, "  - %s (%s)\n", cat.Name, cat.ID)
			}
		} else {
			fmt.Fprintf(logFile, "Selected categories: ALL (full restore)\n")
		}
		fmt.Fprintf(logFile, "Archive: %s\n", filepath.Base(archivePath))
		fmt.Fprintf(logFile, "\n")
	}

	// Extract files (selective or full)
	filesExtracted := 0
	filesSkipped := 0
	filesFailed := 0
	selectiveMode := categories != nil && len(categories) > 0

	var restoredTemp, skippedTemp *os.File
	if logFile != nil {
		if tmp, err := os.CreateTemp("", "restored_entries_*.log"); err == nil {
			restoredTemp = tmp
			defer func() {
				tmp.Close()
				_ = os.Remove(tmp.Name())
			}()
		} else {
			logger.Warning("Could not create temporary file for restored entries: %v", err)
		}

		if tmp, err := os.CreateTemp("", "skipped_entries_*.log"); err == nil {
			skippedTemp = tmp
			defer func() {
				tmp.Close()
				_ = os.Remove(tmp.Name())
			}()
		} else {
			logger.Warning("Could not create temporary file for skipped entries: %v", err)
		}
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		header, err := tarReader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("read tar header: %w", err)
		}

		// Check if file should be extracted (selective mode)
		if selectiveMode {
			shouldExtract := false
			for _, cat := range categories {
				if PathMatchesCategory(header.Name, cat) {
					shouldExtract = true
					break
				}
			}

			if !shouldExtract {
				filesSkipped++
				if skippedTemp != nil {
					fmt.Fprintf(skippedTemp, "SKIPPED: %s (does not match any selected category)\n", header.Name)
				}
				continue
			}
		}

		if err := extractTarEntry(tarReader, header, destRoot, logger); err != nil {
			logger.Warning("Failed to extract %s: %v", header.Name, err)
			filesFailed++
			continue
		}

		filesExtracted++
		if restoredTemp != nil {
			fmt.Fprintf(restoredTemp, "RESTORED: %s\n", header.Name)
		}
		if filesExtracted%100 == 0 {
			logger.Debug("Extracted %d files...", filesExtracted)
		}
	}

	// Write detailed log
	if logFile != nil {
		fmt.Fprintf(logFile, "=== FILES RESTORED ===\n")
		if restoredTemp != nil {
			if _, err := restoredTemp.Seek(0, 0); err == nil {
				if _, err := io.Copy(logFile, restoredTemp); err != nil {
					logger.Warning("Could not write restored entries to log: %v", err)
				}
			}
		}
		fmt.Fprintf(logFile, "\n")

		fmt.Fprintf(logFile, "=== FILES SKIPPED ===\n")
		if skippedTemp != nil {
			if _, err := skippedTemp.Seek(0, 0); err == nil {
				if _, err := io.Copy(logFile, skippedTemp); err != nil {
					logger.Warning("Could not write skipped entries to log: %v", err)
				}
			}
		}
		fmt.Fprintf(logFile, "\n")

		fmt.Fprintf(logFile, "=== SUMMARY ===\n")
		fmt.Fprintf(logFile, "Total files extracted: %d\n", filesExtracted)
		fmt.Fprintf(logFile, "Total files skipped: %d\n", filesSkipped)
		fmt.Fprintf(logFile, "Total files in archive: %d\n", filesExtracted+filesSkipped)
	}

	if filesFailed == 0 {
		if selectiveMode {
			logger.Info("Successfully restored all %d configuration files/directories", filesExtracted)
		} else {
			logger.Info("Successfully restored all %d files/directories", filesExtracted)
		}
	} else {
		logger.Warning("Restored %d files/directories; %d item(s) failed (see detailed log)", filesExtracted, filesFailed)
	}

	if filesSkipped > 0 {
		logger.Info("%d additional archive entries (logs, diagnostics, system defaults) were left unchanged on this system; see detailed log for details", filesSkipped)
	}

	if logFilePath != "" {
		logger.Info("Detailed restore log: %s", logFilePath)
	}

	return nil
}

// createDecompressionReader creates appropriate decompression reader based on file extension
func createDecompressionReader(file *os.File, archivePath string) (io.Reader, error) {
	switch {
	case strings.HasSuffix(archivePath, ".tar.gz") || strings.HasSuffix(archivePath, ".tgz"):
		return gzip.NewReader(file)
	case strings.HasSuffix(archivePath, ".tar.xz"):
		return createXZReader(file)
	case strings.HasSuffix(archivePath, ".tar.zst") || strings.HasSuffix(archivePath, ".tar.zstd"):
		return createZstdReader(file)
	case strings.HasSuffix(archivePath, ".tar.bz2"):
		return createBzip2Reader(file)
	case strings.HasSuffix(archivePath, ".tar.lzma"):
		return createLzmaReader(file)
	case strings.HasSuffix(archivePath, ".tar"):
		return file, nil
	default:
		return nil, fmt.Errorf("unsupported archive format: %s", filepath.Base(archivePath))
	}
}

// createXZReader creates an XZ decompression reader using external xz command
func createXZReader(file *os.File) (io.Reader, error) {
	cmd := exec.Command("xz", "-d", "-c")
	cmd.Stdin = file
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create xz pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start xz: %w", err)
	}
	return stdout, nil
}

// createZstdReader creates a Zstd decompression reader using external zstd command
func createZstdReader(file *os.File) (io.Reader, error) {
	cmd := exec.Command("zstd", "-d", "-c")
	cmd.Stdin = file
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create zstd pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start zstd: %w", err)
	}
	return stdout, nil
}

// createBzip2Reader creates a Bzip2 decompression reader using external bzip2 command
func createBzip2Reader(file *os.File) (io.Reader, error) {
	cmd := exec.Command("bzip2", "-d", "-c")
	cmd.Stdin = file
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create bzip2 pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start bzip2: %w", err)
	}
	return stdout, nil
}

// createLzmaReader creates an LZMA decompression reader using external lzma command
func createLzmaReader(file *os.File) (io.Reader, error) {
	cmd := exec.Command("lzma", "-d", "-c")
	cmd.Stdin = file
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create lzma pipe: %w", err)
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start lzma: %w", err)
	}
	return stdout, nil
}

// extractTarEntry extracts a single TAR entry, preserving all attributes including atime/ctime
func extractTarEntry(tarReader *tar.Reader, header *tar.Header, destRoot string, logger *logging.Logger) error {
	// Clean the target path
	cleanDestRoot := filepath.Clean(destRoot)
	target := filepath.Join(cleanDestRoot, header.Name)
	target = filepath.Clean(target)

	// Security check: prevent path traversal
	safePrefix := cleanDestRoot
	if cleanDestRoot != string(os.PathSeparator) {
		safePrefix = cleanDestRoot + string(os.PathSeparator)
	}

	if !strings.HasPrefix(target, safePrefix) &&
		target != cleanDestRoot {
		return fmt.Errorf("illegal path: %s", header.Name)
	}

	// Create parent directories
	if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
		return fmt.Errorf("create parent directory: %w", err)
	}

	switch header.Typeflag {
	case tar.TypeDir:
		return extractDirectory(target, header, logger)
	case tar.TypeReg:
		return extractRegularFile(tarReader, target, header, logger)
	case tar.TypeSymlink:
		return extractSymlink(target, header, logger)
	case tar.TypeLink:
		return extractHardlink(target, header, destRoot, logger)
	default:
		logger.Debug("Skipping unsupported file type %d: %s", header.Typeflag, header.Name)
		return nil
	}
}

// extractDirectory creates a directory with proper permissions and timestamps
func extractDirectory(target string, header *tar.Header, logger *logging.Logger) error {
	if err := os.MkdirAll(target, os.FileMode(header.Mode)); err != nil {
		return fmt.Errorf("create directory: %w", err)
	}

	// Set ownership
	if err := os.Chown(target, header.Uid, header.Gid); err != nil {
		logger.Debug("Failed to chown directory %s: %v", target, err)
	}

	// Set permissions explicitly
	if err := os.Chmod(target, os.FileMode(header.Mode)); err != nil {
		return fmt.Errorf("chmod directory: %w", err)
	}

	// Set timestamps (mtime, atime)
	if err := setTimestamps(target, header); err != nil {
		logger.Debug("Failed to set timestamps on directory %s: %v", target, err)
	}

	return nil
}

// extractRegularFile extracts a regular file with content and timestamps
func extractRegularFile(tarReader *tar.Reader, target string, header *tar.Header, logger *logging.Logger) error {
	// Remove existing file if it exists
	_ = os.Remove(target)

	// Create the file
	outFile, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode))
	if err != nil {
		return fmt.Errorf("create file: %w", err)
	}
	defer outFile.Close()

	// Copy content
	if _, err := io.Copy(outFile, tarReader); err != nil {
		return fmt.Errorf("write file content: %w", err)
	}

	// Close before setting attributes
	if err := outFile.Close(); err != nil {
		return fmt.Errorf("close file: %w", err)
	}

	// Set ownership
	if err := os.Chown(target, header.Uid, header.Gid); err != nil {
		logger.Debug("Failed to chown file %s: %v", target, err)
	}

	// Set permissions explicitly
	if err := os.Chmod(target, os.FileMode(header.Mode)); err != nil {
		return fmt.Errorf("chmod file: %w", err)
	}

	// Set timestamps (mtime, atime, ctime via syscall)
	if err := setTimestamps(target, header); err != nil {
		logger.Debug("Failed to set timestamps on file %s: %v", target, err)
	}

	return nil
}

// extractSymlink creates a symbolic link
func extractSymlink(target string, header *tar.Header, logger *logging.Logger) error {
	// Remove existing file/link if it exists
	_ = os.Remove(target)

	// Create symlink
	if err := os.Symlink(header.Linkname, target); err != nil {
		return fmt.Errorf("create symlink: %w", err)
	}

	// Set ownership (on the symlink itself, not the target)
	if err := os.Lchown(target, header.Uid, header.Gid); err != nil {
		logger.Debug("Failed to lchown symlink %s: %v", target, err)
	}

	// Note: timestamps on symlinks are not typically preserved
	return nil
}

// extractHardlink creates a hard link
func extractHardlink(target string, header *tar.Header, destRoot string, logger *logging.Logger) error {
	linkTarget := filepath.Join(destRoot, header.Linkname)

	// Remove existing file/link if it exists
	_ = os.Remove(target)

	// Create hard link
	if err := os.Link(linkTarget, target); err != nil {
		return fmt.Errorf("create hardlink: %w", err)
	}

	return nil
}

// setTimestamps sets atime, mtime, and attempts to set ctime via syscall
func setTimestamps(target string, header *tar.Header) error {
	// Convert times to Unix format
	atime := header.AccessTime
	mtime := header.ModTime

	// Use syscall.UtimesNano to set atime and mtime with nanosecond precision
	times := []syscall.Timespec{
		{Sec: atime.Unix(), Nsec: int64(atime.Nanosecond())},
		{Sec: mtime.Unix(), Nsec: int64(mtime.Nanosecond())},
	}

	if err := syscall.UtimesNano(target, times); err != nil {
		return fmt.Errorf("set atime/mtime: %w", err)
	}

	// Note: ctime (change time) cannot be set directly by user-space programs
	// It is automatically updated by the kernel when file metadata changes
	// The header.ChangeTime is stored in PAX but cannot be restored

	return nil
}

// getModeName returns a human-readable name for the restore mode
func getModeName(mode RestoreMode) string {
	switch mode {
	case RestoreModeFull:
		return "FULL restore (all files)"
	case RestoreModeStorage:
		return "STORAGE/DATASTORE only"
	case RestoreModeBase:
		return "SYSTEM BASE only"
	case RestoreModeCustom:
		return "CUSTOM selection"
	default:
		return "Unknown mode"
	}
}

func buildTarExtractArgs(archivePath, destRoot string) ([]string, error) {
	baseArgs := []string{"tar"}
	switch {
	case strings.HasSuffix(archivePath, ".tar.gz") || strings.HasSuffix(archivePath, ".tgz"):
		baseArgs = append(baseArgs, "-xzpf", archivePath, "-C", destRoot)
	case strings.HasSuffix(archivePath, ".tar.bz2"):
		baseArgs = append(baseArgs, "-xjpf", archivePath, "-C", destRoot)
	case strings.HasSuffix(archivePath, ".tar.xz"):
		baseArgs = append(baseArgs, "-xJpf", archivePath, "-C", destRoot)
	case strings.HasSuffix(archivePath, ".tar.lzma"):
		baseArgs = append(baseArgs, "--lzma", "-xpf", archivePath, "-C", destRoot)
	case strings.HasSuffix(archivePath, ".tar.zst") || strings.HasSuffix(archivePath, ".tar.zstd"):
		baseArgs = append(baseArgs, "--use-compress-program=zstd", "-xpf", archivePath, "-C", destRoot)
	case strings.HasSuffix(archivePath, ".tar"):
		baseArgs = append(baseArgs, "-xpf", archivePath, "-C", destRoot)
	default:
		return nil, fmt.Errorf("unsupported archive format: %s", filepath.Base(archivePath))
	}
	return baseArgs, nil
}
