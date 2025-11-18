package storage

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/tis24dev/proxmox-backup/internal/config"
)

type commandCall struct {
	name string
	args []string
}

type queuedResponse struct {
	name string
	args []string
	out  string
	err  error
}

type commandQueue struct {
	t     *testing.T
	queue []queuedResponse
	calls []commandCall
}

func (q *commandQueue) exec(ctx context.Context, name string, args ...string) ([]byte, error) {
	q.calls = append(q.calls, commandCall{name: name, args: append([]string(nil), args...)})
	if len(q.queue) == 0 {
		q.t.Fatalf("unexpected command: %s %v", name, args)
	}
	resp := q.queue[0]
	q.queue = q.queue[1:]

	if resp.name != "" && resp.name != name {
		q.t.Fatalf("expected command %s, got %s", resp.name, name)
	}
	if resp.args != nil {
		if len(resp.args) != len(args) {
			q.t.Fatalf("expected args %v, got %v", resp.args, args)
		}
		for i := range resp.args {
			if resp.args[i] != args[i] {
				q.t.Fatalf("expected args %v, got %v", resp.args, args)
			}
		}
	}
	return []byte(resp.out), resp.err
}

func newCloudStorageForTest(cfg *config.Config) *CloudStorage {
	cs, _ := NewCloudStorage(cfg, newTestLogger())
	return cs
}

func writeTestFile(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0o640); err != nil {
		t.Fatalf("failed to write %s: %v", path, err)
	}
}

func TestCloudStorageUploadWithRetryEventuallySucceeds(t *testing.T) {
	cfg := &config.Config{
		CloudEnabled:           true,
		CloudRemote:            "remote",
		RcloneRetries:          3,
		RcloneTimeoutOperation: 5,
	}
	cs := newCloudStorageForTest(cfg)

	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", err: errors.New("copy failed")},
			{name: "rclone", err: errors.New("copy failed again")},
			{name: "rclone", out: "ok"},
		},
	}
	cs.execCommand = queue.exec
	cs.sleep = func(time.Duration) {}

	if err := cs.uploadWithRetry(context.Background(), "/tmp/local.tar", "remote:local.tar"); err != nil {
		t.Fatalf("uploadWithRetry() error = %v", err)
	}
	if len(queue.calls) != 3 {
		t.Fatalf("expected 3 upload attempts, got %d", len(queue.calls))
	}
}

func TestCloudStorageListParsesBackups(t *testing.T) {
	cfg := &config.Config{
		CloudEnabled: true,
		CloudRemote:  "remote",
	}
	cs := newCloudStorageForTest(cfg)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{
				name: "rclone",
				args: []string{"lsl", "remote:"},
				out: strings.TrimSpace(`
99999 2024-11-12 12:00:00 host-backup-20241112.tar.zst
12000 2024-11-10 08:00:00 proxmox-backup-legacy.tar.gz
555 random line ignored
`),
			},
		},
	}
	cs.execCommand = queue.exec

	backups, err := cs.List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if len(backups) != 2 {
		t.Fatalf("List() = %d backups, want 2", len(backups))
	}
	if backups[0].BackupFile != "host-backup-20241112.tar.zst" {
		t.Fatalf("expected newest backup first, got %s", backups[0].BackupFile)
	}
	if backups[1].BackupFile != "proxmox-backup-legacy.tar.gz" {
		t.Fatalf("expected legacy backup second, got %s", backups[1].BackupFile)
	}
}

func TestCloudStorageDeleteSkipsMissingBundleCandidates(t *testing.T) {
	cfg := &config.Config{
		CloudEnabled:          true,
		CloudRemote:           "remote",
		BundleAssociatedFiles: true,
	}
	cs := newCloudStorageForTest(cfg)
	listOutput := strings.TrimSpace(`
100 2025-01-01 01:00:00 backup/host-backup-20250101-010101.tar.xz
10 2025-01-01 01:00:00 backup/host-backup-20250101-010101.tar.xz.sha256
10 2025-01-01 01:00:00 backup/host-backup-20250101-010101.tar.xz.metadata
10 2025-01-01 01:00:00 backup/host-backup-20250101-010101.tar.xz.metadata.sha256
`)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"lsl", "remote:"}, out: listOutput},
			{name: "rclone", args: []string{"deletefile", "remote:backup/host-backup-20250101-010101.tar.xz"}},
			{name: "rclone", args: []string{"deletefile", "remote:backup/host-backup-20250101-010101.tar.xz.sha256"}},
			{name: "rclone", args: []string{"deletefile", "remote:backup/host-backup-20250101-010101.tar.xz.metadata"}},
			{name: "rclone", args: []string{"deletefile", "remote:backup/host-backup-20250101-010101.tar.xz.metadata.sha256"}},
		},
	}
	cs.execCommand = queue.exec

	backups, err := cs.List(context.Background())
	if err != nil {
		t.Fatalf("List() error = %v", err)
	}
	if len(backups) != 1 {
		t.Fatalf("expected 1 backup, got %d", len(backups))
	}

	if _, err := cs.deleteBackupInternal(context.Background(), backups[0].BackupFile); err != nil {
		t.Fatalf("deleteBackupInternal() error = %v", err)
	}
	if len(queue.calls) != 5 {
		t.Fatalf("expected 5 rclone calls (list + 4 deletes), got %d", len(queue.calls))
	}
}

func TestCloudStorageApplyRetentionDeletesOldest(t *testing.T) {
	cfg := &config.Config{
		CloudEnabled:          true,
		CloudRemote:           "remote",
		CloudBatchSize:        1,
		CloudBatchPause:       0,
		BundleAssociatedFiles: false,
	}
	cs := newCloudStorageForTest(cfg)
	cs.sleep = func(time.Duration) {}

	listOutput := strings.TrimSpace(`
100 2024-11-12 10:00:00 gamma-backup-3.tar.zst
100 2024-11-11 10:00:00 beta-backup-2.tar.zst
100 2024-11-10 10:00:00 alpha-backup-1.tar.zst
`)
	recountOutput := strings.TrimSpace(`
100 2024-11-12 10:00:00 gamma-backup-3.tar.zst
100 2024-11-11 10:00:00 beta-backup-2.tar.zst
`)

	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"lsl", "remote:"}, out: listOutput},
			{name: "rclone", args: []string{"deletefile", "remote:alpha-backup-1.tar.zst"}},
			{name: "rclone", args: []string{"deletefile", "remote:alpha-backup-1.tar.zst.sha256"}},
			{name: "rclone", args: []string{"deletefile", "remote:alpha-backup-1.tar.zst.metadata"}},
			{name: "rclone", args: []string{"deletefile", "remote:alpha-backup-1.tar.zst.metadata.sha256"}},
			{name: "rclone", args: []string{"lsl", "remote:"}, out: recountOutput},
		},
	}
	cs.execCommand = queue.exec

	retentionCfg := RetentionConfig{Policy: "simple", MaxBackups: 2}
	deleted, err := cs.ApplyRetention(context.Background(), retentionCfg)
	if err != nil {
		t.Fatalf("ApplyRetention() error = %v", err)
	}
	if deleted != 1 {
		t.Fatalf("ApplyRetention() deleted = %d, want 1", deleted)
	}
}

func TestCloudStorageStoreUploadsWithRemotePrefix(t *testing.T) {
	tmpDir := t.TempDir()
	backupFile := filepath.Join(tmpDir, "pbs1-backup.tar.zst")
	writeTestFile(t, backupFile, "primary")
	writeTestFile(t, backupFile+".sha256", "sum")
	writeTestFile(t, backupFile+".metadata", "{}")
	writeTestFile(t, backupFile+".metadata.sha256", "meta-sum")

	cfg := &config.Config{
		CloudEnabled:           true,
		CloudRemote:            "remote",
		CloudRemotePath:        "tenants/a",
		BundleAssociatedFiles:  false,
		RcloneRetries:          1,
		RcloneTimeoutOperation: 10,
	}

	cs := newCloudStorageForTest(cfg)
	cs.sleep = func(time.Duration) {}
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile, "remote:tenants/a/pbs1-backup.tar.zst"}},
			{name: "rclone", args: []string{"lsl", "remote:tenants/a/pbs1-backup.tar.zst"}, out: "7 2025-11-13 10:00:00 pbs1-backup.tar.zst"},
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile + ".sha256", "remote:tenants/a/pbs1-backup.tar.zst.sha256"}},
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile + ".metadata", "remote:tenants/a/pbs1-backup.tar.zst.metadata"}},
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile + ".metadata.sha256", "remote:tenants/a/pbs1-backup.tar.zst.metadata.sha256"}},
			{name: "rclone", args: []string{"lsl", "remote:tenants/a"}, out: "7 2025-11-13 10:00:00 pbs1-backup.tar.zst"},
		},
	}
	cs.execCommand = queue.exec

	if err := cs.Store(context.Background(), backupFile, nil); err != nil {
		t.Fatalf("Store() error = %v", err)
	}
	if len(queue.calls) != 6 {
		t.Fatalf("expected 6 rclone calls, got %d", len(queue.calls))
	}
}

func TestCloudStorageStorePrimaryFailure(t *testing.T) {
	tmpDir := t.TempDir()
	backupFile := filepath.Join(tmpDir, "pbs1-backup.tar.zst")
	writeTestFile(t, backupFile, "primary")

	cfg := &config.Config{
		CloudEnabled:           true,
		CloudRemote:            "remote",
		BundleAssociatedFiles:  false,
		RcloneRetries:          1,
		RcloneTimeoutOperation: 5,
	}

	cs := newCloudStorageForTest(cfg)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile, "remote:pbs1-backup.tar.zst"}, err: errors.New("boom")},
		},
	}
	cs.execCommand = queue.exec

	err := cs.Store(context.Background(), backupFile, nil)
	if err == nil {
		t.Fatal("Store() expected error, got nil")
	}
	var storageErr *StorageError
	if !errors.As(err, &storageErr) {
		t.Fatalf("expected StorageError, got %T", err)
	}
	if storageErr.Operation != "upload" {
		t.Fatalf("StorageError.Operation = %s; want upload", storageErr.Operation)
	}
}

func TestCloudStorageStoreAssociatedFailure(t *testing.T) {
	tmpDir := t.TempDir()
	backupFile := filepath.Join(tmpDir, "pbs1-backup.tar.zst")
	writeTestFile(t, backupFile, "primary")
	writeTestFile(t, backupFile+".sha256", "sum")

	cfg := &config.Config{
		CloudEnabled:           true,
		CloudRemote:            "remote",
		BundleAssociatedFiles:  false,
		RcloneRetries:          1,
		RcloneTimeoutOperation: 5,
	}

	cs := newCloudStorageForTest(cfg)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile, "remote:pbs1-backup.tar.zst"}},
			{name: "rclone", args: []string{"lsl", "remote:pbs1-backup.tar.zst"}, out: "7 2025-11-13 10:00:00 pbs1-backup.tar.zst"},
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", backupFile + ".sha256", "remote:pbs1-backup.tar.zst.sha256"}, err: errors.New("assoc failed")},
		},
	}
	cs.execCommand = queue.exec

	err := cs.Store(context.Background(), backupFile, nil)
	if err == nil {
		t.Fatal("Store() expected error, got nil")
	}
	var storageErr *StorageError
	if !errors.As(err, &storageErr) {
		t.Fatalf("expected StorageError, got %T", err)
	}
	if storageErr.Operation != "upload_associated" {
		t.Fatalf("StorageError.Operation = %s; want upload_associated", storageErr.Operation)
	}
}

func TestCloudStorageUploadToRemotePath(t *testing.T) {
	tmpDir := t.TempDir()
	localFile := filepath.Join(tmpDir, "logfile.txt")
	writeTestFile(t, localFile, "log")

	cfg := &config.Config{
		CloudEnabled:           true,
		CloudRemote:            "remote",
		RcloneRetries:          1,
		RcloneTimeoutOperation: 5,
	}

	cs := newCloudStorageForTest(cfg)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{name: "rclone", args: []string{"copyto", "--progress", "--stats", "10s", localFile, "other:logs/logfile.txt"}},
			{name: "rclone", args: []string{"lsl", "other:logs/logfile.txt"}, out: "3 2025-11-13 10:00:00 logfile.txt"},
		},
	}
	cs.execCommand = queue.exec

	if err := cs.UploadToRemotePath(context.Background(), localFile, "other:logs/logfile.txt", true); err != nil {
		t.Fatalf("UploadToRemotePath() error = %v", err)
	}
}

func TestCloudStorageSkipsCloudLogsWhenPathMissing(t *testing.T) {
	cfg := &config.Config{
		CloudEnabled:  true,
		CloudRemote:   "remote",
		CloudLogPath:  "remote:logs",
		RcloneRetries: 1,
	}
	cs := newCloudStorageForTest(cfg)
	queue := &commandQueue{
		t: t,
		queue: []queuedResponse{
			{
				name: "rclone",
				args: []string{"lsf", "remote:logs", "--files-only"},
				out:  "2025/11/16 22:11:47 ERROR : remote:logs: directory not found",
				err:  errors.New("exit status 3"),
			},
		},
	}
	cs.execCommand = queue.exec

	if got := cs.countLogFiles(context.Background()); got != -1 {
		t.Fatalf("countLogFiles() = %d; want -1", got)
	}
	if len(queue.calls) != 1 {
		t.Fatalf("expected 1 rclone call, got %d", len(queue.calls))
	}

	if got := cs.countLogFiles(context.Background()); got != -1 {
		t.Fatalf("countLogFiles() second call = %d; want -1", got)
	}
	if len(queue.calls) != 1 {
		t.Fatalf("expected no additional rclone calls, got %d", len(queue.calls))
	}

	if deleted := cs.deleteAssociatedLog(context.Background(), "host-backup-20250101-010101.tar.xz"); deleted {
		t.Fatal("deleteAssociatedLog() returned true; expected false when log path missing")
	}
	if len(queue.calls) != 1 {
		t.Fatalf("expected no rclone delete when log path missing, got %d calls", len(queue.calls))
	}
}
