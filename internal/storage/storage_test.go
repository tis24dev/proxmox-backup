package storage

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/tis24dev/proxmox-backup/internal/config"
	"github.com/tis24dev/proxmox-backup/internal/logging"
	"github.com/tis24dev/proxmox-backup/internal/types"
)

func newTestLogger() *logging.Logger {
	logger := logging.New(types.LogLevelDebug, false)
	logger.SetOutput(io.Discard)
	return logger
}

func TestNormalizeGFSRetentionConfigEnforcesDailyMinimum(t *testing.T) {
	logger := logging.New(types.LogLevelDebug, false)
	var buf bytes.Buffer
	logger.SetOutput(&buf)

	cfg := RetentionConfig{
		Policy: "gfs",
		Daily:  0,
		Weekly: 4,
	}

	effective := NormalizeGFSRetentionConfig(logger, "Test Storage", cfg)

	if effective.Daily != 1 {
		t.Fatalf("NormalizeGFSRetentionConfig() Daily = %d; want 1", effective.Daily)
	}
	if !strings.Contains(buf.String(), "RETENTION_DAILY") {
		t.Fatalf("expected log message mentioning RETENTION_DAILY adjustment, got: %s", buf.String())
	}
}

func TestLocalStorageListSkipsAssociatedFilesAndSortsByTimestamp(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	cfg := &config.Config{
		BackupPath:            dir,
		BundleAssociatedFiles: true,
	}
	local, err := NewLocalStorage(cfg, newTestLogger())
	if err != nil {
		t.Fatalf("NewLocalStorage() error = %v", err)
	}

	now := time.Now()
	files := []struct {
		name string
		when time.Time
	}{
		{name: "alpha-backup-2024-11-01.tar.zst", when: now.Add(-3 * time.Hour)},
		{name: "beta-backup-2024-11-02.tar.zst", when: now.Add(-1 * time.Hour)},
		{name: "proxmox-backup-legacy.tar.gz", when: now.Add(-2 * time.Hour)},
	}

	for _, file := range files {
		path := filepath.Join(dir, file.name)
		if err := os.WriteFile(path, []byte(file.name), 0o600); err != nil {
			t.Fatalf("write %s: %v", file.name, err)
		}
		if err := os.Chtimes(path, file.when, file.when); err != nil {
			t.Fatalf("chtimes %s: %v", file.name, err)
		}
	}

	// Associated files that should be ignored
	for _, suffix := range []string{".metadata", ".sha256"} {
		name := files[1].name + suffix
		if err := os.WriteFile(filepath.Join(dir, name), []byte("aux"), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}

	backups, err := local.List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}

	if got, want := len(backups), len(files); got != want {
		t.Fatalf("List() = %d backups, want %d", got, want)
	}

	for _, backup := range backups {
		if strings.HasSuffix(backup.BackupFile, ".metadata") || strings.HasSuffix(backup.BackupFile, ".sha256") {
			t.Fatalf("List() returned associated file %s", backup.BackupFile)
		}
	}

	expected := make([]string, len(files))
	order := append([]struct {
		name string
		when time.Time
	}(nil), files...)
	sort.Slice(order, func(i, j int) bool {
		return order[i].when.After(order[j].when)
	})
	for i, file := range order {
		expected[i] = filepath.Join(dir, file.name)
	}

	for i, backup := range backups {
		if backup.BackupFile != expected[i] {
			t.Fatalf("List()[%d] = %s, want %s", i, backup.BackupFile, expected[i])
		}
	}
}

func TestLocalStorageApplyRetentionDeletesOldBackups(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	cfg := &config.Config{
		BackupPath:            dir,
		BundleAssociatedFiles: false,
	}
	local, err := NewLocalStorage(cfg, newTestLogger())
	if err != nil {
		t.Fatalf("NewLocalStorage() error = %v", err)
	}

	now := time.Now()
	type backupMeta struct {
		path string
		mod  time.Time
	}
	var metas []backupMeta
	for i := 0; i < 4; i++ {
		name := filepath.Join(dir, "node-backup-"+time.Now().Add(time.Duration(i)*time.Second).Format("150405")+".tar.zst")
		if err := os.WriteFile(name, []byte{byte(i)}, 0o600); err != nil {
			t.Fatalf("write backup: %v", err)
		}
		mod := now.Add(-time.Duration(i) * time.Minute)
		if err := os.Chtimes(name, mod, mod); err != nil {
			t.Fatalf("chtimes: %v", err)
		}
		for _, suffix := range []string{".metadata", ".metadata.sha256", ".sha256"} {
			if err := os.WriteFile(name+suffix, []byte("aux"), 0o600); err != nil {
				t.Fatalf("write assoc: %v", err)
			}
		}
		metas = append(metas, backupMeta{path: name, mod: mod})
	}

	retentionCfg := RetentionConfig{Policy: "simple", MaxBackups: 2}
	deleted, err := local.ApplyRetention(context.Background(), retentionCfg)
	if err != nil {
		t.Fatalf("ApplyRetention() error = %v", err)
	}
	if deleted != 2 {
		t.Fatalf("ApplyRetention() deleted = %d, want 2", deleted)
	}

	// Determine newest two files (should remain)
	sort.Slice(metas, func(i, j int) bool {
		return metas[i].mod.After(metas[j].mod)
	})
	kept := metas[:2]
	removed := metas[2:]

	for _, meta := range kept {
		if _, err := os.Stat(meta.path); err != nil {
			t.Fatalf("expected backup %s to remain, but stat failed: %v", meta.path, err)
		}
	}

	for _, meta := range removed {
		if _, err := os.Stat(meta.path); !os.IsNotExist(err) {
			t.Fatalf("expected backup %s to be deleted, got err=%v", meta.path, err)
		}
		for _, suffix := range []string{".metadata", ".metadata.sha256", ".sha256"} {
			if _, err := os.Stat(meta.path + suffix); err == nil {
				t.Fatalf("expected associated file %s to be deleted", meta.path+suffix)
			}
		}
	}
}

func TestSecondaryStorageStoreCopiesBackupAndAssociatedFiles(t *testing.T) {
	t.Parallel()

	srcDir := t.TempDir()
	destDir := t.TempDir()

	cfg := &config.Config{
		SecondaryEnabled:      true,
		SecondaryPath:         destDir,
		BundleAssociatedFiles: false,
	}

	secondary, err := NewSecondaryStorage(cfg, newTestLogger())
	if err != nil {
		t.Fatalf("NewSecondaryStorage() error = %v", err)
	}

	backupFile := filepath.Join(srcDir, "pbs-backup-2024.tar.zst")
	if err := os.WriteFile(backupFile, []byte("primary-data"), 0o600); err != nil {
		t.Fatalf("write backup: %v", err)
	}
	for _, suffix := range []string{".metadata", ".metadata.sha256", ".sha256"} {
		if err := os.WriteFile(backupFile+suffix, []byte("data-"+suffix), 0o600); err != nil {
			t.Fatalf("write assoc %s: %v", suffix, err)
		}
	}

	if err := secondary.Store(context.Background(), backupFile, &types.BackupMetadata{}); err != nil {
		t.Fatalf("Secondary store failed: %v", err)
	}

	destFiles := append([]string{backupFile}, backupFile+".metadata", backupFile+".metadata.sha256", backupFile+".sha256")
	for _, src := range destFiles {
		dest := filepath.Join(destDir, filepath.Base(src))
		if _, err := os.Stat(dest); err != nil {
			t.Fatalf("expected %s to exist: %v", dest, err)
		}
		srcData, _ := os.ReadFile(src)
		destData, _ := os.ReadFile(dest)
		if string(srcData) != string(destData) {
			t.Fatalf("copied file %s mismatch", dest)
		}
	}
}

func TestClassifyBackupsGFSLimitsDailyCount(t *testing.T) {
	t.Parallel()

	now := time.Now()

	var backups []*types.BackupMetadata
	for i := 0; i < 5; i++ {
		backups = append(backups, &types.BackupMetadata{
			BackupFile: fmt.Sprintf("backup-%d", i),
			Timestamp:  now.Add(-time.Duration(i) * time.Hour),
		})
	}

	cfg := RetentionConfig{
		Policy: "gfs",
		Daily:  3,
	}

	classification := ClassifyBackupsGFS(backups, cfg)

	countDaily := 0
	for _, cat := range classification {
		if cat == CategoryDaily {
			countDaily++
		}
	}

	if countDaily != 3 {
		t.Fatalf("expected 3 daily backups, got %d", countDaily)
	}
}
