package main

import (
	"fmt"
	"os"
	"path/filepath"

	rootdocs "github.com/tis24dev/proxmox-backup"
	"github.com/tis24dev/proxmox-backup/internal/logging"
)

// installSupportDocs writes embedded documentation files (README, mapping, etc.)
// into the selected base directory so every installation ships with the same
// docs that were present at build time.
func installSupportDocs(baseDir string, bootstrap *logging.BootstrapLogger) error {
	docs := rootdocs.InstallableDocs()
	if len(docs) == 0 {
		return nil
	}

	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return fmt.Errorf("ensure base directory %s: %w", baseDir, err)
	}

	for _, doc := range docs {
		target := filepath.Join(baseDir, doc.Name)
		if err := os.WriteFile(target, doc.Data, 0o644); err != nil {
			return fmt.Errorf("write %s: %w", target, err)
		}
		if bootstrap != nil {
			bootstrap.Info("✓ Installed %s", target)
		}
	}

	return nil
}
