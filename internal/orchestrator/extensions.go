package orchestrator

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/tis24dev/proxmox-backup/internal/storage"
	"github.com/tis24dev/proxmox-backup/internal/types"
)

// StorageTarget rappresenta una destinazione esterna (es. storage secondario, cloud).
type StorageTarget interface {
	Sync(ctx context.Context, stats *BackupStats) error
}

// NotificationChannel rappresenta un canale di notifica (es. Telegram, email).
type NotificationChannel interface {
	Notify(ctx context.Context, stats *BackupStats) error
}

// RegisterStorageTarget aggiunge una destinazione da eseguire dopo il backup.
func (o *Orchestrator) RegisterStorageTarget(target StorageTarget) {
	if target == nil {
		return
	}
	o.storageTargets = append(o.storageTargets, target)
}

// RegisterNotificationChannel aggiunge un canale di notifica da eseguire dopo il backup.
func (o *Orchestrator) RegisterNotificationChannel(channel NotificationChannel) {
	if channel == nil {
		return
	}
	o.notificationChannels = append(o.notificationChannels, channel)
}

func (o *Orchestrator) dispatchNotifications(ctx context.Context, stats *BackupStats) {
	if o == nil || o.logger == nil {
		return
	}

	type notifierEntry struct {
		name    string
		enabled bool
	}

	cfg := o.cfg
	entries := []notifierEntry{
		{name: "Telegram", enabled: cfg != nil && cfg.TelegramEnabled},
		{name: "Email", enabled: cfg != nil && cfg.EmailEnabled},
		{name: "Gotify", enabled: cfg != nil && cfg.GotifyEnabled},
		{name: "Webhook", enabled: cfg != nil && cfg.WebhookEnabled},
	}

	channelIndex := 0
	nextChannel := func() NotificationChannel {
		if channelIndex >= len(o.notificationChannels) {
			return nil
		}
		ch := o.notificationChannels[channelIndex]
		channelIndex++
		return ch
	}

	for _, entry := range entries {
		if !entry.enabled {
			o.logger.Skip("%s: disabled", entry.name)
			continue
		}
		if channel := nextChannel(); channel != nil {
			_ = channel.Notify(ctx, stats) // Ignore errors - notifications are non-critical
		}
	}

	// Dispatch any remaining channels (custom or future ones)
	for channelIndex < len(o.notificationChannels) {
		if channel := nextChannel(); channel != nil {
			_ = channel.Notify(ctx, stats)
		}
	}
}

func (o *Orchestrator) dispatchPostBackup(ctx context.Context, stats *BackupStats) error {
	if o == nil {
		return nil
	}
	// Phase 1: Storage operations (critical - failures abort backup)
	for _, target := range o.storageTargets {
		if err := target.Sync(ctx, stats); err != nil {
			return &BackupError{
				Phase: "storage",
				Err:   fmt.Errorf("storage target failed: %w", err),
				Code:  types.ExitStorageError,
			}
		}
	}

	// Log explicit SKIP lines for disabled storage tiers so that
	// Local / Secondary / Cloud all appear grouped with storage operations.
	if o.logger != nil && stats != nil {
		if !stats.SecondaryEnabled {
			o.logger.Skip("Secondary Storage: disabled")
		}
		if !stats.CloudEnabled {
			o.logger.Skip("Cloud Storage: disabled")
		}
	}

	// Phase 2: Notifications (non-critical - failures don't abort backup)
	// Notification errors are logged but never propagated
	fmt.Println()
	o.logStep(7, "Notifications - dispatching channels")
	o.dispatchNotifications(ctx, stats)

	// Phase 3: Close log file and dispatch to storage/rotation
	fmt.Println()
	o.logStep(8, "Log file management")
	logFilePath := o.logger.GetLogFilePath()
	if logFilePath != "" {
		o.logger.Info("Closing log file: %s", logFilePath)
		if err := o.logger.CloseLogFile(); err != nil {
			o.logger.Warning("Failed to close log file: %v", err)
		} else {
			o.logger.Debug("Log file closed successfully")

			// Copy log to secondary and cloud storage
			if err := o.dispatchLogFile(ctx, logFilePath); err != nil {
				o.logger.Warning("Log file dispatch failed: %v", err)
			}

		}
	} else {
		o.logger.Debug("No log file to close (logging to stdout only)")
	}

	return nil
}

// dispatchLogFile copies the log file to secondary and cloud storage
func (o *Orchestrator) dispatchLogFile(ctx context.Context, logFilePath string) error {
	if o.cfg == nil {
		return nil
	}

	logFileName := filepath.Base(logFilePath)
	o.logger.Info("Dispatching log file: %s", logFileName)

	// Copy to secondary storage
	if o.cfg.SecondaryEnabled && o.cfg.SecondaryLogPath != "" {
		secondaryLogPath := filepath.Join(o.cfg.SecondaryLogPath, logFileName)
		o.logger.Debug("Copying log to secondary: %s", secondaryLogPath)

		if err := os.MkdirAll(o.cfg.SecondaryLogPath, 0755); err != nil {
			o.logger.Warning("Failed to create secondary log directory: %v", err)
		} else {
			if err := copyFile(logFilePath, secondaryLogPath); err != nil {
				o.logger.Warning("Failed to copy log to secondary: %v", err)
			} else {
				o.logger.Info("✓ Log copied to secondary: %s", secondaryLogPath)
			}
		}
	}

	// Copy to cloud storage
	if o.cfg.CloudEnabled {
		if cloudBase := strings.TrimSpace(o.cfg.CloudLogPath); cloudBase != "" {
			destination := buildCloudLogDestination(cloudBase, logFileName)
			o.logger.Debug("Copying log to cloud: %s", destination)

			if err := o.copyLogToCloud(ctx, logFilePath, destination); err != nil {
				o.logger.Warning("Failed to copy log to cloud: %v", err)
			} else {
				o.logger.Info("✓ Log copied to cloud: %s", destination)
			}
		}
	}

	return nil
}

// copyLogToCloud copies a log file to cloud storage using rclone
func (o *Orchestrator) copyLogToCloud(ctx context.Context, sourcePath, destPath string) error {
	if !strings.Contains(destPath, ":") {
		return fmt.Errorf("cloud log path must include an rclone remote (es. remote:/logs): %s", destPath)
	}

	client, err := storage.NewCloudStorage(o.cfg, o.logger)
	if err != nil {
		return fmt.Errorf("failed to initialize cloud storage: %w", err)
	}

	return client.UploadToRemotePath(ctx, sourcePath, destPath, true)
}

func buildCloudLogDestination(basePath, fileName string) string {
	base := strings.TrimSpace(basePath)
	if base == "" {
		return fileName
	}
	base = strings.TrimRight(base, "/")
	if strings.HasSuffix(base, ":") {
		return base + fileName
	}
	if strings.Contains(base, ":") {
		return base + "/" + fileName
	}
	return filepath.Join(base, fileName)
}
