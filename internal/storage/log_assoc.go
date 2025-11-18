package storage

import (
	"path/filepath"
	"strings"
)

// extractLogKeyFromBackup attempts to derive the hostname and timestamp key
// from a backup filename using the Go naming scheme:
//
//	<hostname>-backup-<YYYYMMDD-HHMMSS>.<ext...>
//
// It returns hostname and timestamp string (YYYYMMDD-HHMMSS) if successful.
func extractLogKeyFromBackup(backupFile string) (hostname, timestamp string, ok bool) {
	base := filepath.Base(backupFile)

	// Require "-backup-" marker
	const marker = "-backup-"
	idx := strings.Index(base, marker)
	if idx <= 0 {
		return "", "", false
	}

	host := base[:idx]
	rest := base[idx+len(marker):]
	if host == "" || rest == "" {
		return "", "", false
	}

	// Strip extensions after the timestamp
	if dot := strings.Index(rest, "."); dot > 0 {
		rest = rest[:dot]
	}

	// Expect timestamp in the form 20060102-150405 (15 chars)
	if len(rest) != len("20060102-150405") {
		return "", "", false
	}

	return host, rest, true
}

func computeRemaining(initial, deleted int) (int, bool) {
	if initial < 0 {
		return 0, false
	}
	remaining := initial - deleted
	if remaining < 0 {
		remaining = 0
	}
	return remaining, true
}
