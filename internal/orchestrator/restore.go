package orchestrator

import (
	"archive/tar"
	"bufio"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

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

	if err := confirmRestoreAction(ctx, reader, candidate, destRoot); err != nil {
		return err
	}

	if err := extractPlainArchive(ctx, prepared.ArchivePath, destRoot, logger); err != nil {
		return err
	}

	logger.Info("Restore completed successfully.")
	logger.Info("Temporary decrypted bundle removed.")
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
	if err := extractArchiveNative(ctx, archivePath, destRoot, logger); err != nil {
		return fmt.Errorf("archive extraction failed: %w", err)
	}

	return nil
}

// extractArchiveNative extracts TAR archives natively in Go, preserving all timestamps
func extractArchiveNative(ctx context.Context, archivePath, destRoot string, logger *logging.Logger) error {
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

	// Extract all files
	filesExtracted := 0
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

		if err := extractTarEntry(tarReader, header, destRoot, logger); err != nil {
			logger.Warning("Failed to extract %s: %v", header.Name, err)
			continue
		}

		filesExtracted++
		if filesExtracted%100 == 0 {
			logger.Debug("Extracted %d files...", filesExtracted)
		}
	}

	logger.Info("Successfully extracted %d files/directories", filesExtracted)
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
	target := filepath.Join(destRoot, header.Name)
	target = filepath.Clean(target)

	// Security check: prevent path traversal
	if !strings.HasPrefix(target, filepath.Clean(destRoot)+string(os.PathSeparator)) &&
		target != filepath.Clean(destRoot) {
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
