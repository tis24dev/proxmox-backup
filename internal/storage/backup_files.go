package storage

import "strings"

// trimBundleSuffix removes the .bundle.tar suffix from a path if present.
// It returns the trimmed path and whether the suffix was removed.
func trimBundleSuffix(path string) (string, bool) {
	if strings.HasSuffix(path, ".bundle.tar") {
		return strings.TrimSuffix(path, ".bundle.tar"), true
	}
	return path, false
}

// buildBackupCandidatePaths returns the list of files that belong to a backup.
// When includeBundle is true, both the bundle and the legacy single-file layout
// are included so retention can clean up either form.
func buildBackupCandidatePaths(base string, includeBundle bool) []string {
	seen := make(map[string]struct{})
	add := func(path string) bool {
		if path == "" {
			return false
		}
		if _, ok := seen[path]; ok {
			return false
		}
		seen[path] = struct{}{}
		return true
	}

	files := make([]string, 0, 5)
	if includeBundle {
		if add(base + ".bundle.tar") {
			files = append(files, base+".bundle.tar")
		}
	}
	candidates := []string{
		base,
		base + ".sha256",
		base + ".metadata",
		base + ".metadata.sha256",
	}
	for _, c := range candidates {
		if add(c) {
			files = append(files, c)
		}
	}
	return files
}
