package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/tis24dev/proxmox-backup/internal/backup"
	"github.com/tis24dev/proxmox-backup/internal/checks"
	"github.com/tis24dev/proxmox-backup/internal/cli"
	"github.com/tis24dev/proxmox-backup/internal/config"
	"github.com/tis24dev/proxmox-backup/internal/environment"
	"github.com/tis24dev/proxmox-backup/internal/identity"
	"github.com/tis24dev/proxmox-backup/internal/logging"
	"github.com/tis24dev/proxmox-backup/internal/notify"
	"github.com/tis24dev/proxmox-backup/internal/orchestrator"
	"github.com/tis24dev/proxmox-backup/internal/security"
	"github.com/tis24dev/proxmox-backup/internal/storage"
	"github.com/tis24dev/proxmox-backup/internal/types"
	"github.com/tis24dev/proxmox-backup/pkg/utils"
	"golang.org/x/term"
)

const (
	version              = "0.9.0" // Semantic version format required by cloud relay worker
	defaultLegacyEnvPath = "/opt/proxmox-backup/env/backup.env"
)

// Build-time variables (injected via ldflags)
var (
	buildTime = "" // Will be set during compilation via -ldflags "-X main.buildTime=..."
)

func main() {
	code := run()
	status := notify.StatusFromExitCode(code)
	statusLabel := strings.ToUpper(status.String())
	emoji := notify.GetStatusEmoji(status)
	logging.Info("Final exit status: %s %s (code=%d)", emoji, statusLabel, code)
	os.Exit(code)
}

var closeStdinOnce sync.Once

func run() int {
	bootstrap := logging.NewBootstrapLogger()
	finalExitCode := types.ExitSuccess.Int()

	defer func() {
		if r := recover(); r != nil {
			stack := debug.Stack()
			bootstrap.Error("PANIC: %v", r)
			fmt.Fprintf(os.Stderr, "panic: %v\n%s\n", r, stack)
			os.Exit(types.ExitPanicError.Int())
		}
	}()

	// Setup signal handling for graceful shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Handle SIGINT (Ctrl+C) and SIGTERM
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		sig := <-sigChan
		bootstrap.Warning("\nReceived signal %v, initiating graceful shutdown...", sig)
		cancel() // Cancel context to stop all operations
		closeStdinOnce.Do(func() {
			if file := os.Stdin; file != nil {
				_ = file.Close()
			}
		})
	}()

	// Parse command-line arguments
	args := cli.Parse()

	// Handle version flag
	if args.ShowVersion {
		cli.ShowVersion()
		return types.ExitSuccess.Int()
	}

	// Handle help flag
	if args.ShowHelp {
		cli.ShowHelp()
		return types.ExitSuccess.Int()
	}

	// Resolve configuration path relative to the executable's base directory so
	// that configs/ is located consistently next to the binary, regardless of
	// the current working directory.
	resolvedConfigPath, err := resolveInstallConfigPath(args.ConfigPath)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}
	args.ConfigPath = resolvedConfigPath

	// Handle configuration upgrade dry-run (plan-only, no writes).
	if args.UpgradeConfigDry {
		if err := ensureConfigExists(args.ConfigPath, bootstrap); err != nil {
			bootstrap.Error("ERROR: %v", err)
			return types.ExitConfigError.Int()
		}

		bootstrap.Printf("Planning configuration upgrade using embedded template: %s", args.ConfigPath)
		result, err := config.PlanUpgradeConfigFile(args.ConfigPath)
		if err != nil {
			bootstrap.Error("ERROR: Failed to plan configuration upgrade: %v", err)
			return types.ExitConfigError.Int()
		}
		if !result.Changed {
			bootstrap.Println("Configuration is already up to date with the embedded template; no changes are required.")
			return types.ExitSuccess.Int()
		}

		if len(result.MissingKeys) > 0 {
			bootstrap.Printf("Missing keys that would be added from the template (%d): %s",
				len(result.MissingKeys), strings.Join(result.MissingKeys, ", "))
		}
		if result.PreservedValues > 0 {
			bootstrap.Printf("Existing values that would be preserved: %d", result.PreservedValues)
		}
		if len(result.ExtraKeys) > 0 {
			bootstrap.Printf("Custom keys that would be preserved (not present in template) (%d): %s",
				len(result.ExtraKeys), strings.Join(result.ExtraKeys, ", "))
		}
		bootstrap.Println("Dry run only: no files were modified. Use --upgrade-config to apply these changes.")
		return types.ExitSuccess.Int()
	}

	// Handle install wizard (runs before normal execution)
	if args.Install {
		if err := runInstall(ctx, args.ConfigPath, bootstrap); err != nil {
			bootstrap.Error("ERROR: %v", err)
			return types.ExitConfigError.Int()
		}
		return types.ExitSuccess.Int()
	}

	// Pre-flight: enforce Go runtime version
	if err := checkGoRuntimeVersion("1.25.4"); err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitEnvironmentError.Int()
	}

	// Print header
	bootstrap.Println("===========================================")
	bootstrap.Println("  Proxmox Backup - Go Version")
	bootstrap.Printf("  Version: %s", version)
	if sig := buildSignature(); sig != "" {
		bootstrap.Printf("  Build Signature: %s", sig)
	}
	bootstrap.Println("===========================================")
	bootstrap.Println("")

	// Detect Proxmox environment
	bootstrap.Println("Detecting Proxmox environment...")
	envInfo, err := environment.Detect()
	if err != nil {
		bootstrap.Warning("WARNING: %v", err)
		bootstrap.Println("Continuing with limited functionality...")
	}
	bootstrap.Printf("✓ Proxmox Type: %s", envInfo.Type)
	bootstrap.Printf("  Version: %s", envInfo.Version)
	bootstrap.Println("")

	// Handle configuration upgrade (schema-aware merge with embedded template).
	if args.UpgradeConfig {
		if err := ensureConfigExists(args.ConfigPath, bootstrap); err != nil {
			bootstrap.Error("ERROR: %v", err)
			return types.ExitConfigError.Int()
		}

		bootstrap.Printf("Upgrading configuration file: %s", args.ConfigPath)
		result, err := config.UpgradeConfigFile(args.ConfigPath)
		if err != nil {
			bootstrap.Error("ERROR: Failed to upgrade configuration: %v", err)
			return types.ExitConfigError.Int()
		}
		if !result.Changed {
			bootstrap.Println("Configuration is already up to date with the embedded template; no changes were made.")
			return types.ExitSuccess.Int()
		}

		bootstrap.Println("Configuration upgraded successfully!")
		if len(result.MissingKeys) > 0 {
			bootstrap.Printf("- Added %d missing key(s): %s",
				len(result.MissingKeys), strings.Join(result.MissingKeys, ", "))
		} else {
			bootstrap.Println("- No new keys were required from the template")
		}
		if result.PreservedValues > 0 {
			bootstrap.Printf("- Preserved %d existing value(s) from current configuration", result.PreservedValues)
		}
		if len(result.ExtraKeys) > 0 {
			bootstrap.Printf("- Kept %d custom key(s) not present in the template: %s",
				len(result.ExtraKeys), strings.Join(result.ExtraKeys, ", "))
		}
		if result.BackupPath != "" {
			bootstrap.Printf("- Backup saved to: %s", result.BackupPath)
		}
		bootstrap.Println("✓ Configuration upgrade completed successfully.")
		return types.ExitSuccess.Int()
	}

	if args.EnvMigrationDry {
		return runEnvMigrationDry(ctx, args, bootstrap)
	}

	if args.EnvMigration {
		return runEnvMigration(ctx, args, bootstrap)
	}

	// Load configuration
	autoBaseDir, autoFound := detectBaseDir()
	if autoBaseDir == "" {
		autoBaseDir = "/opt/proxmox-backup"
	}
	initialEnvBaseDir := os.Getenv("BASE_DIR")
	if initialEnvBaseDir == "" {
		_ = os.Setenv("BASE_DIR", autoBaseDir)
	}

	if err := ensureConfigExists(args.ConfigPath, bootstrap); err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	bootstrap.Printf("Loading configuration from: %s", args.ConfigPath)
	cfg, err := config.LoadConfig(args.ConfigPath)
	if err != nil {
		bootstrap.Error("ERROR: Failed to load configuration: %v", err)
		return types.ExitConfigError.Int()
	}
	if cfg.BaseDir == "" {
		cfg.BaseDir = autoBaseDir
	}
	_ = os.Setenv("BASE_DIR", cfg.BaseDir)
	bootstrap.Println("✓ Configuration loaded successfully")

	// Show dry-run status early in bootstrap phase
	dryRun := args.DryRun || cfg.DryRun
	if dryRun {
		if args.DryRun {
			bootstrap.Println("⚠ DRY RUN MODE (enabled via --dry-run flag)")
		} else {
			bootstrap.Println("⚠ DRY RUN MODE (enabled via DRY_RUN config)")
		}
	}
	bootstrap.Println("")

	if err := validateFutureFeatures(cfg); err != nil {
		bootstrap.Error("ERROR: Invalid configuration: %v", err)
		return types.ExitConfigError.Int()
	}

	// Validate log path configuration early to avoid "cosmetic only" logging.
	// If a log feature is enabled but its path is empty, disable the path-driven
	// behavior and document the detection to the user.
	if strings.TrimSpace(cfg.LogPath) == "" {
		bootstrap.Warning("WARNING: LOG_PATH is empty - file logging disabled, using stdout only")
	}
	if cfg.SecondaryEnabled && strings.TrimSpace(cfg.SecondaryLogPath) == "" {
		bootstrap.Warning("WARNING: Secondary storage enabled but SECONDARY_LOG_PATH is empty - secondary log copy and cleanup will be disabled for this run")
	}
	if cfg.CloudEnabled && strings.TrimSpace(cfg.CloudLogPath) == "" {
		bootstrap.Warning("WARNING: Cloud storage enabled but CLOUD_LOG_PATH is empty - cloud log copy and cleanup will be disabled for this run")
	}

	// Pre-flight: if features require network, verify basic connectivity
	if needs, reasons := featuresNeedNetwork(cfg); needs {
		if cfg.DisableNetworkPreflight {
			logging.Warning("WARNING: Network preflight disabled via DISABLE_NETWORK_PREFLIGHT; features: %s", strings.Join(reasons, ", "))
		} else {
			if err := checkInternetConnectivity(2 * time.Second); err != nil {
				bootstrap.Warning("WARNING: Network connectivity unavailable for: %s. %v", strings.Join(reasons, ", "), err)
				bootstrap.Warning("WARNING: Disabling network-dependent features for this run")
				disableNetworkFeaturesForRun(cfg, bootstrap)
			}
		}
	}

	// Determine log level (CLI overrides config)
	logLevel := cfg.DebugLevel
	if args.LogLevel != types.LogLevelNone {
		logLevel = args.LogLevel
	}

	// Initialize logger with configuration
	logger := logging.New(logLevel, cfg.UseColor)
	logging.SetDefaultLogger(logger)
	bootstrap.SetLevel(logLevel)
	bootstrap.Flush(logger)

	// Open log file for real-time writing (will be closed after notifications)
	hostname := resolveHostname()
	startTime := time.Now()
	timestampStr := startTime.Format("20060102-150405")
	logFileName := fmt.Sprintf("backup-%s-%s.log", hostname, timestampStr)
	logFilePath := filepath.Join(cfg.LogPath, logFileName)

	// Ensure log directory exists
	if err := os.MkdirAll(cfg.LogPath, 0755); err != nil {
		logging.Warning("Failed to create log directory %s: %v", cfg.LogPath, err)
	} else {
		if err := logger.OpenLogFile(logFilePath); err != nil {
			logging.Warning("Failed to open log file %s: %v", logFilePath, err)
		} else {
			logging.Info("Log file opened: %s", logFilePath)
			// Store log path in environment for backup stats
			_ = os.Setenv("LOG_FILE", logFilePath)
		}
	}

	// Apply backup permissions (optional, Bash-compatible behavior)
	if cfg.SetBackupPermissions {
		if err := applyBackupPermissions(cfg, logger); err != nil {
			logging.Warning("Failed to apply backup permissions: %v", err)
		}
	}

	defer cleanupAfterRun(logger)

	// Log dry-run status in main logger (already shown in bootstrap)
	if dryRun {
		if args.DryRun {
			logging.Info("DRY RUN MODE: No actual changes will be made (enabled via --dry-run flag)")
		} else {
			logging.Info("DRY RUN MODE: No actual changes will be made (enabled via DRY_RUN config)")
		}
	}

	// Determine base directory source for logging
	baseDirSource := "default fallback"
	if rawBaseDir, ok := cfg.Get("BASE_DIR"); ok && strings.TrimSpace(rawBaseDir) != "" {
		baseDirSource = "configured in backup.env"
	} else if initialEnvBaseDir != "" {
		baseDirSource = "from environment (BASE_DIR)"
	} else if autoFound {
		baseDirSource = "auto-detected from executable path"
	}

	// Log environment info
	logging.Info("Environment: %s %s", envInfo.Type, envInfo.Version)
	logging.Info("Backup enabled: %v", cfg.BackupEnabled)
	logging.Info("Debug level: %s", logLevel.String())
	logging.Info("Compression: %s (level %d, mode %s)", cfg.CompressionType, cfg.CompressionLevel, cfg.CompressionMode)
	logging.Info("Base directory: %s (%s)", cfg.BaseDir, baseDirSource)
	configSource := args.ConfigPathSource
	if configSource == "" {
		configSource = "configured path"
	}
	logging.Info("Configuration file: %s (%s)", args.ConfigPath, configSource)

	var identityInfo *identity.Info
	serverIDValue := strings.TrimSpace(cfg.ServerID)
	serverMACValue := ""
	telegramServerStatus := "Telegram disabled"
	if info, err := identity.Detect(cfg.BaseDir, logger); err != nil {
		logging.Warning("WARNING: Failed to load server identity: %v", err)
		identityInfo = info
	} else {
		identityInfo = info
	}

	if identityInfo != nil {
		if identityInfo.ServerID != "" {
			serverIDValue = identityInfo.ServerID
		}
		if identityInfo.PrimaryMAC != "" {
			serverMACValue = identityInfo.PrimaryMAC
		}
	}

	if serverIDValue != "" && cfg.ServerID == "" {
		cfg.ServerID = serverIDValue
	}

	logServerIdentityValues(serverIDValue, serverMACValue)
	logTelegramInfo := true
	if cfg.TelegramEnabled {
		if strings.EqualFold(cfg.TelegramBotType, "centralized") {
			logging.Debug("Contacting remote Telegram server...")
			status := notify.CheckTelegramRegistration(ctx, cfg.TelegramServerAPIHost, serverIDValue, logger)
			if status.Error != nil {
				logging.Warning("Telegram: %s", status.Message)
				logTelegramInfo = false
			} else {
				logging.Debug("Remote server contacted: Bot token / chat ID verified (handshake)")
			}
			telegramServerStatus = status.Message
		} else {
			telegramServerStatus = "Personal mode - no remote contact"
		}
	}
	if logTelegramInfo {
		logging.Info("Server Telegram: %s", telegramServerStatus)
	}
	fmt.Println()

	execInfo := getExecInfo()
	execPath := execInfo.ExecPath
	if _, secErr := security.Run(ctx, logger, cfg, args.ConfigPath, execPath, envInfo); secErr != nil {
		logging.Error("Security checks failed: %v", secErr)
		return types.ExitSecurityError.Int()
	}
	fmt.Println()

	if args.Restore {
		logging.Info("Restore mode enabled - starting interactive workflow...")
		if err := orchestrator.RunRestoreWorkflow(ctx, cfg, logger, version); err != nil {
			if errors.Is(err, orchestrator.ErrRestoreAborted) || errors.Is(err, orchestrator.ErrDecryptAborted) {
				logging.Info("Restore workflow aborted by user")
				return types.ExitSuccess.Int()
			}
			logging.Error("Restore workflow failed: %v", err)
			return types.ExitGenericError.Int()
		}
		logging.Info("Restore workflow completed successfully")
		return types.ExitSuccess.Int()
	}

	if args.Decrypt {
		logging.Info("Decrypt mode enabled - starting interactive workflow...")
		if err := orchestrator.RunDecryptWorkflow(ctx, cfg, logger, version); err != nil {
			if errors.Is(err, orchestrator.ErrDecryptAborted) {
				logging.Info("Decrypt workflow aborted by user")
				return types.ExitSuccess.Int()
			}
			logging.Error("Decrypt workflow failed: %v", err)
			return types.ExitGenericError.Int()
		}
		logging.Info("Decrypt workflow completed successfully")
		return types.ExitSuccess.Int()
	}

	// Initialize orchestrator
	logging.Step("Initializing backup orchestrator")
	bashScriptPath := "/opt/proxmox-backup/script"
	orch := orchestrator.New(logger, bashScriptPath, dryRun)
	orch.SetForceNewAgeRecipient(args.ForceNewKey)
	orch.SetVersion(version)
	orch.SetConfig(cfg)
	orch.SetIdentity(serverIDValue, serverMACValue)
	orch.SetProxmoxVersion(envInfo.Version)
	orch.SetStartTime(startTime)

	// Configure backup paths and compression
	excludePatterns := append([]string(nil), cfg.ExcludePatterns...)
	excludePatterns = addPathExclusion(excludePatterns, cfg.BackupPath)
	if cfg.SecondaryEnabled {
		excludePatterns = addPathExclusion(excludePatterns, cfg.SecondaryPath)
	}
	if cfg.CloudEnabled && isLocalPath(cfg.CloudRemote) {
		excludePatterns = addPathExclusion(excludePatterns, cfg.CloudRemote)
	}

	orch.SetBackupConfig(
		cfg.BackupPath,
		cfg.LogPath,
		cfg.CompressionType,
		cfg.CompressionLevel,
		cfg.CompressionThreads,
		cfg.CompressionMode,
		excludePatterns,
	)

	orch.SetOptimizationConfig(backup.OptimizationConfig{
		EnableChunking:            cfg.EnableSmartChunking,
		EnableDeduplication:       cfg.EnableDeduplication,
		EnablePrefilter:           cfg.EnablePrefilter,
		ChunkSizeBytes:            int64(cfg.ChunkSizeMB) * 1024 * 1024,
		ChunkThresholdBytes:       int64(cfg.ChunkThresholdMB) * 1024 * 1024,
		PrefilterMaxFileSizeBytes: int64(cfg.PrefilterMaxFileSizeMB) * 1024 * 1024,
	})

	// Dedicated mode: --newkey only runs AGE setup
	if args.ForceNewKey {
		logging.Info("New AGE key setup mode enabled (--newkey)")
		if err := orch.EnsureAgeRecipientsReady(ctx); err != nil {
			if errors.Is(err, orchestrator.ErrAgeRecipientSetupAborted) {
				logging.Warning("Encryption setup aborted by user. Exiting...")
				return types.ExitGenericError.Int()
			}
			logging.Error("ERROR: %v", err)
			return types.ExitConfigError.Int()
		}
		logging.Info("✓ AGE recipients updated successfully; no backup will be run (--newkey)")
		return types.ExitSuccess.Int()
	}

	if err := orch.EnsureAgeRecipientsReady(ctx); err != nil {
		if errors.Is(err, orchestrator.ErrAgeRecipientSetupAborted) {
			logging.Warning("Encryption setup aborted by user. Exiting...")
			return types.ExitGenericError.Int()
		}
		logging.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	logging.Info("✓ Orchestrator initialized")
	fmt.Println()

	// Verify directories
	logging.Step("Verifying directory structure")
	checkDir := func(name, path string) {
		if utils.DirExists(path) {
			logging.Info("✓ %s exists: %s", name, path)
		} else {
			logging.Warning("✗ %s not found: %s", name, path)
		}
	}

	checkDir("Backup directory", cfg.BackupPath)
	checkDir("Log directory", cfg.LogPath)
	if cfg.SecondaryEnabled {
		secondaryLogPath := strings.TrimSpace(cfg.SecondaryLogPath)
		if secondaryLogPath != "" {
			checkDir("Secondary log directory", secondaryLogPath)
		} else {
			logging.Warning("✗ Secondary log directory not configured (secondary storage enabled)")
		}
	}
	if cfg.CloudEnabled {
		cloudLogPath := strings.TrimSpace(cfg.CloudLogPath)
		if cloudLogPath == "" {
			logging.Warning("✗ Cloud log directory not configured (cloud storage enabled)")
		} else if isLocalPath(cloudLogPath) {
			checkDir("Cloud log directory", cloudLogPath)
		} else {
			logging.Info("Skipping local validation for cloud log directory (remote path): %s", cloudLogPath)
		}
	}
	checkDir("Lock directory", cfg.LockPath)

	// Initialize pre-backup checker
	logging.Debug("Configuring pre-backup validation checks...")
	checkerConfig := checks.GetDefaultCheckerConfig(cfg.BackupPath, cfg.LogPath, cfg.LockPath)
	checkerConfig.SecondaryEnabled = cfg.SecondaryEnabled
	if cfg.SecondaryEnabled && strings.TrimSpace(cfg.SecondaryPath) != "" {
		checkerConfig.SecondaryPath = cfg.SecondaryPath
	} else {
		checkerConfig.SecondaryPath = ""
	}
	checkerConfig.CloudEnabled = cfg.CloudEnabled
	if cfg.CloudEnabled && strings.TrimSpace(cfg.CloudRemote) != "" {
		checkerConfig.CloudPath = cfg.CloudRemote
	} else {
		checkerConfig.CloudPath = ""
	}
	checkerConfig.MinDiskPrimaryGB = cfg.MinDiskPrimaryGB
	checkerConfig.MinDiskSecondaryGB = cfg.MinDiskSecondaryGB
	checkerConfig.MinDiskCloudGB = cfg.MinDiskCloudGB
	checkerConfig.DryRun = dryRun
	if err := checkerConfig.Validate(); err != nil {
		logging.Error("Invalid checker configuration: %v", err)
		return types.ExitConfigError.Int()
	}
	checker := checks.NewChecker(logger, checkerConfig)
	orch.SetChecker(checker)

	// Ensure lock is released on exit
	defer func() {
		if err := orch.ReleaseBackupLock(); err != nil {
			logging.Warning("Failed to release backup lock: %v", err)
		}
	}()

	logging.Debug("✓ Pre-backup checks configured")
	fmt.Println()

	// Initialize storage backends
	logging.Step("Initializing storage backends")

	// Primary (local) storage - always enabled
	localBackend, err := storage.NewLocalStorage(cfg, logger)
	if err != nil {
		logging.Error("Failed to initialize local storage: %v", err)
		return types.ExitConfigError.Int()
	}
	localFS, err := detectFilesystemInfo(ctx, localBackend, cfg.BackupPath, logger)
	if err != nil {
		logging.Error("Failed to prepare primary storage: %v", err)
		return types.ExitConfigError.Int()
	}
	logging.Info("Path Primary: %s", formatDetailedFilesystemLabel(cfg.BackupPath, localFS))

	localStats := fetchStorageStats(ctx, localBackend, logger, "Local storage")
	localBackups := fetchBackupList(ctx, localBackend)

	localAdapter := orchestrator.NewStorageAdapter(localBackend, logger, cfg)
	localAdapter.SetFilesystemInfo(localFS)
	localAdapter.SetInitialStats(localStats)
	orch.RegisterStorageTarget(localAdapter)
	logStorageInitSummary(formatStorageInitSummary("Local storage", cfg, storage.LocationPrimary, localStats, localBackups))

	// Secondary storage - optional
	var secondaryFS *storage.FilesystemInfo
	if cfg.SecondaryEnabled {
		secondaryBackend, err := storage.NewSecondaryStorage(cfg, logger)
		if err != nil {
			logging.Warning("Failed to initialize secondary storage: %v", err)
			logging.Info("Path Secondary: %s", formatDetailedFilesystemLabel(cfg.SecondaryPath, nil))
		} else {
			secondaryFS, _ = detectFilesystemInfo(ctx, secondaryBackend, cfg.SecondaryPath, logger)
			logging.Info("Path Secondary: %s", formatDetailedFilesystemLabel(cfg.SecondaryPath, secondaryFS))
			secondaryStats := fetchStorageStats(ctx, secondaryBackend, logger, "Secondary storage")
			secondaryBackups := fetchBackupList(ctx, secondaryBackend)
			secondaryAdapter := orchestrator.NewStorageAdapter(secondaryBackend, logger, cfg)
			secondaryAdapter.SetFilesystemInfo(secondaryFS)
			secondaryAdapter.SetInitialStats(secondaryStats)
			orch.RegisterStorageTarget(secondaryAdapter)
			logStorageInitSummary(formatStorageInitSummary("Secondary storage", cfg, storage.LocationSecondary, secondaryStats, secondaryBackups))
		}
	} else {
		logging.Skip("Path Secondary: disabled")
	}

	// Cloud storage - optional
	var cloudFS *storage.FilesystemInfo
	if cfg.CloudEnabled {
		cloudBackend, err := storage.NewCloudStorage(cfg, logger)
		if err != nil {
			logging.Warning("Failed to initialize cloud storage: %v", err)
			logging.Info("Path Cloud: %s", formatDetailedFilesystemLabel(cfg.CloudRemote, nil))
			logStorageInitSummary(formatStorageInitSummary("Cloud storage", cfg, storage.LocationCloud, nil, nil))
		} else {
			cloudFS, _ = detectFilesystemInfo(ctx, cloudBackend, cfg.CloudRemote, logger)
			if cloudFS == nil {
				cfg.CloudEnabled = false
				cfg.CloudLogPath = ""
				if checker != nil {
					checker.DisableCloud()
				}
				logStorageInitSummary(formatStorageInitSummary("Cloud storage", cfg, storage.LocationCloud, nil, nil))
				logging.Skip("Path Cloud: disabled")
			} else {
				logging.Info("Path Cloud: %s", formatDetailedFilesystemLabel(cfg.CloudRemote, cloudFS))
				cloudStats := fetchStorageStats(ctx, cloudBackend, logger, "Cloud storage")
				cloudBackups := fetchBackupList(ctx, cloudBackend)
				cloudAdapter := orchestrator.NewStorageAdapter(cloudBackend, logger, cfg)
				cloudAdapter.SetFilesystemInfo(cloudFS)
				cloudAdapter.SetInitialStats(cloudStats)
				orch.RegisterStorageTarget(cloudAdapter)
				logStorageInitSummary(formatStorageInitSummary("Cloud storage", cfg, storage.LocationCloud, cloudStats, cloudBackups))
			}
		}
	} else {
		logging.Skip("Path Cloud: disabled")
	}

	fmt.Println()

	// Initialize notification channels
	logging.Step("Initializing notification channels")

	// Telegram notifications
	if cfg.TelegramEnabled {
		telegramConfig := notify.TelegramConfig{
			Enabled:       true,
			Mode:          notify.TelegramMode(cfg.TelegramBotType),
			BotToken:      cfg.TelegramBotToken,
			ChatID:        cfg.TelegramChatID,
			ServerAPIHost: cfg.TelegramServerAPIHost,
			ServerID:      cfg.ServerID,
		}
		telegramNotifier, err := notify.NewTelegramNotifier(telegramConfig, logger)
		if err != nil {
			logging.Warning("Failed to initialize Telegram notifier: %v", err)
		} else {
			telegramAdapter := orchestrator.NewNotificationAdapter(telegramNotifier, logger)
			orch.RegisterNotificationChannel(telegramAdapter)
			logging.Info("✓ Telegram initialized (mode: %s)", cfg.TelegramBotType)
		}
	} else {
		logging.Skip("Telegram: disabled")
	}

	// Email notifications
	if cfg.EmailEnabled {
		emailConfig := notify.EmailConfig{
			Enabled:          true,
			DeliveryMethod:   notify.EmailDeliveryMethod(cfg.EmailDeliveryMethod),
			FallbackSendmail: cfg.EmailFallbackSendmail,
			Recipient:        cfg.EmailRecipient,
			From:             cfg.EmailFrom,
			CloudRelayConfig: notify.CloudRelayConfig{
				WorkerURL:   cfg.CloudflareWorkerURL,
				WorkerToken: cfg.CloudflareWorkerToken,
				HMACSecret:  cfg.CloudflareHMACSecret,
				Timeout:     cfg.WorkerTimeout,
				MaxRetries:  cfg.WorkerMaxRetries,
				RetryDelay:  cfg.WorkerRetryDelay,
			},
		}
		emailNotifier, err := notify.NewEmailNotifier(emailConfig, envInfo.Type, logger)
		if err != nil {
			logging.Warning("Failed to initialize Email notifier: %v", err)
		} else {
			emailAdapter := orchestrator.NewNotificationAdapter(emailNotifier, logger)
			orch.RegisterNotificationChannel(emailAdapter)
			logging.Info("✓ Email initialized (method: %s)", cfg.EmailDeliveryMethod)
		}
	} else {
		logging.Skip("Email: disabled")
	}

	// Gotify notifications
	if cfg.GotifyEnabled {
		gotifyConfig := notify.GotifyConfig{
			Enabled:         true,
			ServerURL:       cfg.GotifyServerURL,
			Token:           cfg.GotifyToken,
			PrioritySuccess: cfg.GotifyPrioritySuccess,
			PriorityWarning: cfg.GotifyPriorityWarning,
			PriorityFailure: cfg.GotifyPriorityFailure,
		}
		gotifyNotifier, err := notify.NewGotifyNotifier(gotifyConfig, logger)
		if err != nil {
			logging.Warning("Failed to initialize Gotify notifier: %v", err)
		} else {
			gotifyAdapter := orchestrator.NewNotificationAdapter(gotifyNotifier, logger)
			orch.RegisterNotificationChannel(gotifyAdapter)
			logging.Info("✓ Gotify initialized")
		}
	} else {
		logging.Skip("Gotify: disabled")
	}

	// Webhook Notifications
	if cfg.WebhookEnabled {
		logging.Debug("Initializing webhook notifier...")
		webhookConfig := cfg.BuildWebhookConfig()
		logging.Debug("Webhook config built: %d endpoints configured", len(webhookConfig.Endpoints))

		webhookNotifier, err := notify.NewWebhookNotifier(webhookConfig, logger)
		if err != nil {
			logging.Warning("Failed to initialize Webhook notifier: %v", err)
		} else {
			logging.Debug("Creating webhook notification adapter...")
			webhookAdapter := orchestrator.NewNotificationAdapter(webhookNotifier, logger)

			logging.Debug("Registering webhook notification channel with orchestrator...")
			orch.RegisterNotificationChannel(webhookAdapter)
			logging.Info("✓ Webhook initialized (%d endpoint(s))", len(webhookConfig.Endpoints))
		}
	} else {
		logging.Skip("Webhook: disabled")
	}

	fmt.Println()

	useGoPipeline := cfg.EnableGoBackup

	// Validate / report hybrid (bash) mode
	if useGoPipeline {
		// Go pipeline attiva: gli script bash non sono richiesti
		logging.Skip("Hybrid mode: disabled")
	} else {
		if utils.DirExists(bashScriptPath) {
			logging.Info("Validating bash script environment...")
			logging.Info("✓ Bash scripts directory exists: %s", bashScriptPath)
		} else {
			logging.Info("✗ Bash scripts directory not found: %s", bashScriptPath)
			logging.Skip("Hybrid mode: disabled")
		}
	}
	fmt.Println()

	// Storage info
	logging.Info("Storage configuration:")
	logging.Info("  Primary: %s", formatStorageLabel(cfg.BackupPath, localFS))
	if cfg.SecondaryEnabled {
		logging.Info("  Secondary storage: %s", formatStorageLabel(cfg.SecondaryPath, secondaryFS))
	} else {
		logging.Skip("  Secondary storage: disabled")
	}
	if cfg.CloudEnabled {
		logging.Info("  Cloud storage: %s", formatStorageLabel(cfg.CloudRemote, cloudFS))
	} else {
		logging.Skip("  Cloud storage: disabled")
	}
	fmt.Println()

	// Log configuration info
	logging.Info("Log configuration:")
	logging.Info("  Primary: %s", cfg.LogPath)
	if cfg.SecondaryEnabled {
		if strings.TrimSpace(cfg.SecondaryLogPath) != "" {
			logging.Info("  Secondary: %s", cfg.SecondaryLogPath)
		} else {
			logging.Skip("  Secondary: disabled (log path not configured)")
		}
	} else {
		logging.Skip("  Secondary: disabled")
	}
	if cfg.CloudEnabled {
		if strings.TrimSpace(cfg.CloudLogPath) != "" {
			logging.Info("  Cloud: %s", cfg.CloudLogPath)
		} else {
			logging.Skip("  Cloud: disabled (log path not configured)")
		}
	} else {
		logging.Skip("  Cloud: disabled")
	}
	fmt.Println()

	// Notification info
	logging.Info("Notification configuration:")
	logging.Info("  Telegram: %v", cfg.TelegramEnabled)
	logging.Info("  Email: %v", cfg.EmailEnabled)
	logging.Info("  Gotify: %v", cfg.GotifyEnabled)
	logging.Info("  Webhook: %v", cfg.WebhookEnabled)
	logging.Info("  Metrics: %v", cfg.MetricsEnabled)
	fmt.Println()

	if useGoPipeline {
		logging.Debug("Go backup pipeline enabled")
	} else {
		logging.Info("Go backup pipeline disabled (ENABLE_GO_BACKUP=false).")
		logging.Info("Using legacy bash workflow.")
	}

	// Run backup orchestration
	if cfg.BackupEnabled {
		if useGoPipeline {
			if err := orch.RunPreBackupChecks(ctx); err != nil {
				logging.Error("Pre-backup validation failed: %v", err)
				return types.ExitBackupError.Int()
			}
			fmt.Println()

			logging.Step("Start Go backup orchestration")

			// Get hostname for backup naming
			hostname := resolveHostname()

			// Run Go-based backup (collection + archive)
			stats, err := orch.RunGoBackup(ctx, envInfo.Type, hostname)
			if err != nil {
				// Check if error is due to cancellation
				if ctx.Err() == context.Canceled {
					logging.Warning("Backup was canceled")
					return 128 + int(syscall.SIGINT) // Standard Unix exit code for SIGINT
				}

				// Check if it's a BackupError with specific exit code
				var backupErr *orchestrator.BackupError
				if errors.As(err, &backupErr) {
					logging.Error("Backup %s failed: %v", backupErr.Phase, backupErr.Err)
					return backupErr.Code.Int()
				}

				// Generic backup error
				logging.Error("Backup orchestration failed: %v", err)
				return types.ExitBackupError.Int()
			}

			if err := orch.SaveStatsReport(stats); err != nil {
				logging.Warning("Failed to persist backup statistics: %v", err)
			} else if stats.ReportPath != "" {
				logging.Info("✓ Statistics report saved to %s", stats.ReportPath)
			}

			// Display backup statistics
			fmt.Println()
			logging.Info("=== Backup Statistics ===")
			logging.Info("Files collected: %d", stats.FilesCollected)
			if stats.FilesFailed > 0 {
				logging.Warning("Files failed: %d", stats.FilesFailed)
			}
			logging.Info("Directories created: %d", stats.DirsCreated)
			logging.Info("Data collected: %s", formatBytes(stats.BytesCollected))
			logging.Info("Archive size: %s", formatBytes(stats.ArchiveSize))
			switch {
			case stats.CompressionSavingsPercent > 0:
				logging.Info("Compression ratio: %.1f%%", stats.CompressionSavingsPercent)
			case stats.CompressionRatioPercent > 0:
				logging.Info("Compression ratio: %.1f%%", stats.CompressionRatioPercent)
			case stats.BytesCollected > 0:
				ratio := float64(stats.ArchiveSize) / float64(stats.BytesCollected) * 100
				logging.Info("Compression ratio: %.1f%%", ratio)
			default:
				logging.Info("Compression ratio: N/A")
			}
			logging.Info("Compression used: %s (level %d, mode %s)", stats.Compression, stats.CompressionLevel, stats.CompressionMode)
			if stats.RequestedCompression != stats.Compression {
				logging.Info("Requested compression: %s", stats.RequestedCompression)
			}
			logging.Info("Duration: %s", formatDuration(stats.Duration))
			if stats.BundleCreated {
				logging.Info("Bundle path: %s", stats.ArchivePath)
				logging.Info("Bundle contents: archive + checksum + metadata")
			} else {
				logging.Info("Archive path: %s", stats.ArchivePath)
				if stats.ManifestPath != "" {
					logging.Info("Manifest path: %s", stats.ManifestPath)
				}
				if stats.Checksum != "" {
					logging.Info("Archive checksum (SHA256): %s", stats.Checksum)
				}
			}
			fmt.Println()

			logging.Info("✓ Go backup orchestration completed")
			logServerIdentityValues(serverIDValue, serverMACValue)

			exitCode := stats.ExitCode
			status := notify.StatusFromExitCode(exitCode)
			statusLabel := strings.ToUpper(status.String())
			emoji := notify.GetStatusEmoji(status)
			logging.Info("Exit status: %s %s (code=%d)", emoji, statusLabel, exitCode)
			finalExitCode = exitCode
		} else {
			logging.Info("Starting legacy bash backup orchestration...")
			if err := orch.RunBackup(ctx, envInfo.Type); err != nil {
				if ctx.Err() == context.Canceled {
					logging.Warning("Backup was canceled")
					return 128 + int(syscall.SIGINT)
				}
				logging.Error("Bash backup orchestration failed: %v", err)
				return types.ExitBackupError.Int()
			}
			logging.Info("✓ Bash backup orchestration completed")
			logServerIdentityValues(serverIDValue, serverMACValue)
		}
	} else {
		logging.Warning("Backup is disabled in configuration")
	}
	fmt.Println()

	// Summary
	fmt.Println("===========================================")
	fmt.Println("Status: Phase 5.1 Notifications")
	fmt.Println("===========================================")
	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  proxmox-backup     - Start backup")
	fmt.Println("  make test          - Run all tests")
	fmt.Println("  make build         - Build binary")
	fmt.Println("  --help             - Show all options")
	fmt.Println("  --dry-run          - Test without changes")
	fmt.Println("  --install          - Re-run interactive installation/setup")
	fmt.Println("  --env-migration    - Run installer and migrate legacy Bash backup.env to Go template")
	fmt.Println("  --env-migration-dry-run - Preview installer/migration without writing files")
	fmt.Println("  --newkey           - Generate a new encryption key for backups")
	fmt.Println("  --decrypt          - Decrypt an existing backup archive")
	fmt.Println("  --restore          - Restore data from a decrypted backup")
	fmt.Println("  --upgrade-config   - Upgrade configuration file using the embedded template (run after installing a new binary)")
	fmt.Println("  --upgrade-config-dry-run - Show differences between current configuration and the embedded template without modifying files")
	fmt.Println()

	return finalExitCode
}

// checkGoRuntimeVersion ensures the running binary was built with at least the specified Go version (semver: major.minor.patch).
func checkGoRuntimeVersion(min string) error {
	rt := runtime.Version() // e.g., "go1.25.4"
	// Normalize versions to x.y.z
	parse := func(v string) (int, int, int) {
		// Accept forms: go1.25.4, go1.25, 1.25.4, 1.25
		v = strings.TrimPrefix(v, "go")
		parts := strings.Split(v, ".")
		toInt := func(s string) int { n, _ := strconv.Atoi(s); return n }
		major, minor, patch := 0, 0, 0
		if len(parts) > 0 {
			major = toInt(parts[0])
		}
		if len(parts) > 1 {
			minor = toInt(parts[1])
		}
		if len(parts) > 2 {
			patch = toInt(parts[2])
		}
		return major, minor, patch
	}

	rtMaj, rtMin, rtPatch := parse(rt)
	minMaj, minMin, minPatch := parse(min)

	newer := func(aMaj, aMin, aPatch, bMaj, bMin, bPatch int) bool {
		if aMaj != bMaj {
			return aMaj > bMaj
		}
		if aMin != bMin {
			return aMin > bMin
		}
		return aPatch >= bPatch
	}

	if !newer(rtMaj, rtMin, rtPatch, minMaj, minMin, minPatch) {
		return fmt.Errorf("Go runtime version %s is below required %s — rebuild with Go %s or set GOTOOLCHAIN=auto", rt, "go"+min, "go"+min)
	}
	return nil
}

// featuresNeedNetwork returns whether current configuration requires outbound network, and human reasons.
func featuresNeedNetwork(cfg *config.Config) (bool, []string) {
	reasons := []string{}
	// Telegram (any mode uses network)
	if cfg.TelegramEnabled {
		if strings.EqualFold(cfg.TelegramBotType, "centralized") {
			reasons = append(reasons, "Telegram centralized registration")
		} else {
			reasons = append(reasons, "Telegram personal notifications")
		}
	}
	// Email via relay
	if cfg.EmailEnabled && strings.EqualFold(cfg.EmailDeliveryMethod, "relay") {
		reasons = append(reasons, "Email relay delivery")
	}
	// Gotify
	if cfg.GotifyEnabled {
		reasons = append(reasons, "Gotify notifications")
	}
	// Webhooks
	if cfg.WebhookEnabled {
		reasons = append(reasons, "Webhooks")
	}
	// Cloud uploads via rclone
	if cfg.CloudEnabled {
		reasons = append(reasons, "Cloud storage (rclone)")
	}
	return len(reasons) > 0, reasons
}

// disableNetworkFeaturesForRun disables all network-dependent features when connectivity is unavailable.
func disableNetworkFeaturesForRun(cfg *config.Config, bootstrap *logging.BootstrapLogger) {
	if cfg == nil {
		return
	}
	warn := func(format string, args ...interface{}) {
		if bootstrap != nil {
			bootstrap.Warning(format, args...)
			return
		}
		logging.Warning(format, args...)
	}

	if cfg.CloudEnabled {
		warn("WARNING: Disabling cloud storage (rclone) due to missing network connectivity")
		cfg.CloudEnabled = false
		cfg.CloudLogPath = ""
	}

	if cfg.TelegramEnabled {
		warn("WARNING: Disabling Telegram notifications due to missing network connectivity")
		cfg.TelegramEnabled = false
	}

	if cfg.EmailEnabled && strings.EqualFold(cfg.EmailDeliveryMethod, "relay") {
		if cfg.EmailFallbackSendmail {
			warn("WARNING: Network unavailable; switching Email delivery to sendmail for this run")
			cfg.EmailDeliveryMethod = "sendmail"
		} else {
			warn("WARNING: Disabling Email relay notifications due to missing network connectivity")
			cfg.EmailEnabled = false
		}
	}

	if cfg.GotifyEnabled {
		warn("WARNING: Disabling Gotify notifications due to missing network connectivity")
		cfg.GotifyEnabled = false
	}

	if cfg.WebhookEnabled {
		warn("WARNING: Disabling Webhook notifications due to missing network connectivity")
		cfg.WebhookEnabled = false
	}
}

// checkInternetConnectivity attempts a couple of quick TCP dials to common endpoints.
// It succeeds if at least one attempt connects.
func checkInternetConnectivity(timeout time.Duration) error {
	type target struct{ network, addr string }
	targets := []target{
		{"tcp", "1.1.1.1:443"},
		{"tcp", "8.8.8.8:53"},
	}
	deadline := time.Now().Add(timeout)
	for _, t := range targets {
		d := net.Dialer{Timeout: time.Until(deadline)}
		if conn, err := d.Dial(t.network, t.addr); err == nil {
			_ = conn.Close()
			return nil
		}
	}
	return fmt.Errorf("no outbound connectivity (checked %d endpoints)", len(targets))
}

// formatBytes formats bytes in human-readable format
func formatBytes(bytes int64) string {
	const unit = 1024
	if bytes < unit {
		return fmt.Sprintf("%d B", bytes)
	}
	div, exp := int64(unit), 0
	for n := bytes / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.1f %ciB", float64(bytes)/float64(div), "KMGTPE"[exp])
}

// formatDuration formats a duration in human-readable format
func formatDuration(d time.Duration) string {
	if d < time.Minute {
		return fmt.Sprintf("%.1fs", d.Seconds())
	}
	if d < time.Hour {
		return fmt.Sprintf("%.1fm", d.Minutes())
	}
	return fmt.Sprintf("%.1fh", d.Hours())
}

func logServerIdentityValues(serverID, mac string) {
	serverID = strings.TrimSpace(serverID)
	mac = strings.TrimSpace(mac)
	if serverID != "" {
		logging.Info("Server ID: %s", serverID)
	}
	if mac != "" {
		logging.Info("Server MAC Address: %s", mac)
	}
}

func resolveHostname() string {
	if path, err := exec.LookPath("hostname"); err == nil {
		if out, err := exec.Command(path, "-f").Output(); err == nil {
			if fqdn := strings.TrimSpace(string(out)); fqdn != "" {
				return fqdn
			}
		}
	}

	host, err := os.Hostname()
	if err != nil {
		return "unknown"
	}

	host = strings.TrimSpace(host)
	if host == "" {
		return "unknown"
	}
	return host
}

func validateFutureFeatures(cfg *config.Config) error {
	if cfg.SecondaryEnabled && cfg.SecondaryPath == "" {
		return fmt.Errorf("secondary backup enabled but SECONDARY_PATH is empty")
	}
	if cfg.CloudEnabled && cfg.CloudRemote == "" {
		logging.Warning("Cloud backup enabled but CLOUD_REMOTE is empty – disabling cloud storage for this run")
		cfg.CloudEnabled = false
		cfg.CloudRemote = ""
		cfg.CloudLogPath = ""
	}
	// Telegram validation - only for personal mode
	if cfg.TelegramEnabled && cfg.TelegramBotType == "personal" {
		if cfg.TelegramBotToken == "" || cfg.TelegramChatID == "" {
			return fmt.Errorf("telegram personal mode enabled but TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID missing")
		}
	}
	// Email recipient validation - auto-detection is allowed
	// No validation needed here as email notifier will handle it
	if cfg.MetricsEnabled && cfg.MetricsPath == "" {
		return fmt.Errorf("metrics enabled but METRICS_PATH is empty")
	}
	return nil
}

type configStatusLogger interface {
	Warning(format string, args ...interface{})
	Info(format string, args ...interface{})
}

// migrateLegacyEnvIfPresent checks for a legacy Bash env file (env/backup.env)
// under likely base directories and, if found, generates a new Go-style
// configs/backup.env by overlaying legacy key=values onto the default template.
func migrateLegacyEnvIfPresent(newConfigPath string, logger configStatusLogger) (bool, error) {
	newConfigPath = strings.TrimSpace(newConfigPath)
	if newConfigPath == "" {
		return false, fmt.Errorf("empty config path for migration")
	}

	// Candidate base directories: derived from config path, from executable info, and the legacy default.
	var baseDirs []string
	if dir := filepath.Dir(filepath.Dir(newConfigPath)); dir != "" && dir != "." && dir != string(filepath.Separator) {
		baseDirs = append(baseDirs, dir)
	}
	if info := getExecInfo(); info.BaseDir != "" {
		baseDirs = append(baseDirs, info.BaseDir)
	}
	baseDirs = append(baseDirs, "/opt/proxmox-backup")

	seen := make(map[string]struct{})
	var legacyEnvPath string
	for _, dir := range baseDirs {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			continue
		}
		if _, ok := seen[dir]; ok {
			continue
		}
		seen[dir] = struct{}{}
		candidate := filepath.Join(dir, "env", "backup.env")
		info, err := os.Stat(candidate)
		if err != nil {
			if !os.IsNotExist(err) {
				logger.Warning("WARNING: Failed to stat legacy env candidate %s: %v", candidate, err)
			}
			continue
		}
		if info.IsDir() {
			continue
		}
		legacyEnvPath = candidate
		break
	}

	if legacyEnvPath == "" {
		return false, nil
	}

	logger.Info("Detected legacy env configuration at %s; migrating to %s", legacyEnvPath, newConfigPath)

	data, err := os.ReadFile(legacyEnvPath)
	if err != nil {
		return false, fmt.Errorf("failed to read legacy env file %s: %w", legacyEnvPath, err)
	}

	legacyKV := parseKeyValues(string(data))
	template := config.DefaultEnvTemplate()

	// Overlay all legacy keys onto the template; Go parser will ignore unknown keys.
	for k, v := range legacyKV {
		if strings.TrimSpace(k) == "" {
			continue
		}
		template = setEnvValue(template, k, v)
	}

	// Ensure BASE_DIR is explicitly set and consistent with the new config location.
	baseDir := filepath.Dir(filepath.Dir(newConfigPath))
	if baseDir == "" || baseDir == "." || baseDir == string(filepath.Separator) {
		if info := getExecInfo(); info.BaseDir != "" {
			baseDir = info.BaseDir
		} else {
			baseDir = "/opt/proxmox-backup"
		}
	}
	template = setEnvValue(template, "BASE_DIR", baseDir)

	dir := filepath.Dir(newConfigPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return false, fmt.Errorf("failed to create configuration directory %s: %w", dir, err)
	}
	if err := os.WriteFile(newConfigPath, []byte(template), 0o600); err != nil {
		return false, fmt.Errorf("failed to write migrated configuration: %w", err)
	}

	logger.Info("✓ Migrated legacy env to %s", newConfigPath)
	return true, nil
}

// parseKeyValues parses a simple KEY=VALUE env-style file, ignoring comments and
// stripping surrounding quotes and inline comments from the value.
func parseKeyValues(raw string) map[string]string {
	result := make(map[string]string)
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Ignore shebang or non KEY=VALUE lines
		if strings.HasPrefix(line, "#!") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if key == "" {
			continue
		}
		rest := strings.TrimSpace(line[idx+1:])
		// Strip inline comments (unquoted)
		if hash := strings.Index(rest, "#"); hash >= 0 {
			rest = strings.TrimSpace(rest[:hash])
		}
		// Strip surrounding single or double quotes
		if len(rest) >= 2 {
			if (rest[0] == '"' && rest[len(rest)-1] == '"') ||
				(rest[0] == '\'' && rest[len(rest)-1] == '\'') {
				rest = rest[1 : len(rest)-1]
			}
		}
		if rest == "" {
			continue
		}
		result[key] = rest
	}
	return result
}

func ensureConfigExists(path string, logger configStatusLogger) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("configuration path is empty")
	}

	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("failed to stat configuration file: %w", err)
	}

	// Attempt automatic migration from legacy Bash env (env/backup.env) if present.
	if migrated, err := migrateLegacyEnvIfPresent(path, logger); err != nil {
		logger.Warning("WARNING: Failed to migrate legacy env file: %v", err)
	} else if migrated {
		return nil
	}

	logger.Warning("Configuration file not found: %s", path)
	fmt.Print("Generate default configuration from template? [y/N]: ")

	reader := bufio.NewReader(os.Stdin)
	response, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return fmt.Errorf("failed to read user input: %w", err)
	}

	answer := strings.ToLower(strings.TrimSpace(response))
	if answer != "y" && answer != "yes" {
		return fmt.Errorf("configuration file is required to continue")
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("failed to create configuration directory %s: %w", dir, err)
	}

	if err := os.WriteFile(path, []byte(config.DefaultEnvTemplate()), 0o600); err != nil {
		return fmt.Errorf("failed to write default configuration: %w", err)
	}

	logger.Info("✓ Default configuration created at %s", path)
	return nil
}

type ExecInfo struct {
	ExecPath string
	ExecDir  string
	BaseDir  string
	HasBase  bool
}

var (
	execInfo     ExecInfo
	execInfoOnce sync.Once
)

func getExecInfo() ExecInfo {
	execInfoOnce.Do(func() {
		execInfo = detectExecInfo()
	})
	return execInfo
}

func detectExecInfo() ExecInfo {
	execPath, err := os.Executable()
	if err != nil {
		return ExecInfo{}
	}

	if resolved, err := filepath.EvalSymlinks(execPath); err == nil && resolved != "" {
		execPath = resolved
	}

	execDir := filepath.Dir(execPath)
	dir := execDir
	originalDir := dir
	baseDir := ""

	for {
		if dir == "" || dir == "." || dir == string(filepath.Separator) {
			break
		}
		if info, err := os.Stat(filepath.Join(dir, "env")); err == nil && info.IsDir() {
			baseDir = dir
			break
		}
		if info, err := os.Stat(filepath.Join(dir, "script")); err == nil && info.IsDir() {
			baseDir = dir
			break
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}

	if baseDir == "" {
		if parent := filepath.Dir(originalDir); parent != "" && parent != "." && parent != string(filepath.Separator) {
			baseDir = parent
		}
	}

	return ExecInfo{
		ExecPath: execPath,
		ExecDir:  execDir,
		BaseDir:  baseDir,
		HasBase:  baseDir != "",
	}
}

func detectBaseDir() (string, bool) {
	info := getExecInfo()
	return info.BaseDir, info.HasBase
}

func detectFilesystemInfo(ctx context.Context, backend storage.Storage, path string, logger *logging.Logger) (*storage.FilesystemInfo, error) {
	if backend == nil || !backend.IsEnabled() {
		return nil, nil
	}

	fsInfo, err := backend.DetectFilesystem(ctx)
	if err != nil {
		if backend.IsCritical() {
			return nil, err
		}
		logger.Debug("WARNING: %s filesystem detection failed: %v", backend.Name(), err)
		return nil, nil
	}

	if !fsInfo.SupportsOwnership {
		logger.Warning("%s [%s] does not support ownership changes; chown/chmod will be skipped", path, fsInfo.Type)
	}

	return fsInfo, nil
}

func formatStorageLabel(path string, info *storage.FilesystemInfo) string {
	fsType := "unknown"
	if info != nil && info.Type != "" {
		fsType = string(info.Type)
	}
	return fmt.Sprintf("%s [%s]", path, fsType)
}

func formatDetailedFilesystemLabel(path string, info *storage.FilesystemInfo) string {
	cleanPath := strings.TrimSpace(path)
	if cleanPath == "" {
		return "disabled"
	}
	if info == nil {
		return fmt.Sprintf("%s -> Filesystem: unknown (detection unavailable)", cleanPath)
	}

	ownership := "no ownership"
	if info.SupportsOwnership {
		ownership = "supports ownership"
	}

	network := ""
	if info.IsNetworkFS {
		network = " [network]"
	}

	mount := info.MountPoint
	if mount == "" {
		mount = "unknown"
	}

	return fmt.Sprintf("%s -> Filesystem: %s (%s)%s [mount: %s]",
		cleanPath,
		info.Type,
		ownership,
		network,
		mount,
	)
}

func fetchStorageStats(ctx context.Context, backend storage.Storage, logger *logging.Logger, label string) *storage.StorageStats {
	if ctx.Err() != nil || backend == nil || !backend.IsEnabled() {
		return nil
	}
	stats, err := backend.GetStats(ctx)
	if err != nil {
		logger.Debug("%s: unable to gather stats: %v", label, err)
		return nil
	}
	return stats
}

func formatStorageInitSummary(name string, cfg *config.Config, location storage.BackupLocation, stats *storage.StorageStats, backups []*types.BackupMetadata) string {
	// Build retention config to check policy type
	retentionConfig := storage.NewRetentionConfigFromConfig(cfg, location)

	if stats == nil {
		// No stats available (backend likely reported warnings)
		reason := "unable to gather stats"
		if retentionConfig.Policy == "gfs" {
			return fmt.Sprintf("⚠ %s initialized with warnings (%s; GFS retention: daily=%d, weekly=%d, monthly=%d, yearly=%d)",
				name, reason, retentionConfig.Daily, retentionConfig.Weekly,
				retentionConfig.Monthly, retentionConfig.Yearly)
		}
		return fmt.Sprintf("⚠ %s initialized with warnings (%s; retention %s)", name, reason, formatBackupNoun(retentionConfig.MaxBackups))
	}

	// Stats available - show current backup count
	if retentionConfig.Policy == "gfs" {
		// GFS mode - show detailed breakdown
		result := fmt.Sprintf("✓ %s initialized (present %s)", name, formatBackupNoun(stats.TotalBackups))

		// If we have backups, classify them and show stats
		if stats.TotalBackups > 0 && backups != nil && len(backups) > 0 {
			classification := storage.ClassifyBackupsGFS(backups, retentionConfig)
			gfsStats := storage.GetRetentionStats(classification)

			total := stats.TotalBackups
			kept := total - gfsStats[storage.CategoryDelete]

			result += fmt.Sprintf("\n  Total: %d/-", total)
			result += fmt.Sprintf("\n  Daily: %d/%d", gfsStats[storage.CategoryDaily], retentionConfig.Daily)
			result += fmt.Sprintf("\n  Weekly: %d/%d", gfsStats[storage.CategoryWeekly], retentionConfig.Weekly)
			result += fmt.Sprintf("\n  Monthly: %d/%d", gfsStats[storage.CategoryMonthly], retentionConfig.Monthly)
			result += fmt.Sprintf("\n  Yearly: %d/%d", gfsStats[storage.CategoryYearly], retentionConfig.Yearly)
			result += fmt.Sprintf("\n  Kept (est.): %d, To delete (est.): %d", kept, gfsStats[storage.CategoryDelete])
		} else {
			// No backups yet - show configured limits
			result += fmt.Sprintf("\n  Daily: 0/%d, Weekly: 0/%d, Monthly: 0/%d, Yearly: 0/%d",
				retentionConfig.Daily, retentionConfig.Weekly,
				retentionConfig.Monthly, retentionConfig.Yearly)
		}
		return result
	}

	// Simple retention mode - format uniformly with GFS
	result := fmt.Sprintf("✓ %s initialized (present %s)", name, formatBackupNoun(stats.TotalBackups))
	result += fmt.Sprintf("\n  Policy: simple (keep %d newest)", retentionConfig.MaxBackups)
	return result
}

func logStorageInitSummary(summary string) {
	if summary == "" {
		return
	}
	for _, line := range strings.Split(summary, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "⚠") {
			logging.Warning("%s", line)
			continue
		}
		if strings.Contains(trimmed, "Kept (est.):") {
			logging.Debug("%s", line)
		} else {
			logging.Info("%s", line)
		}
	}
}

func formatBackupNoun(n int) string {
	if n == 1 {
		return "1 backup"
	}
	return fmt.Sprintf("%d backups", n)
}

// cleanupLegacyBashSymlinks scans common bin directories for symlinks that
// point to legacy bash scripts under baseDir/script and removes them.
func cleanupLegacyBashSymlinks(baseDir string, bootstrap *logging.BootstrapLogger) {
	baseDir = strings.TrimSpace(baseDir)
	if baseDir == "" {
		baseDir = "/opt/proxmox-backup"
	}

	// Collect all existing legacy script targets (resolved paths) from likely install roots.
	legacyTargets := map[string]struct{}{}
	addLegacyDir := func(dir string) {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			return
		}
		scriptDir := filepath.Join(dir, "script")
		if info, err := os.Stat(scriptDir); err != nil || !info.IsDir() {
			return
		}
		for _, name := range []string{
			"proxmox-backup.sh",
			"security-check.sh",
			"fix-permissions.sh",
			"proxmox-restore.sh",
		} {
			path := filepath.Join(scriptDir, name)
			if _, err := os.Stat(path); err != nil {
				continue
			}
			if resolved, err := filepath.EvalSymlinks(path); err == nil && resolved != "" {
				legacyTargets[resolved] = struct{}{}
			} else {
				legacyTargets[path] = struct{}{}
			}
		}
	}

	// Primary: the detected baseDir for this binary; Fallback: the default legacy install dir.
	addLegacyDir(baseDir)
	if baseDir != "/opt/proxmox-backup" {
		addLegacyDir("/opt/proxmox-backup")
	}

	if len(legacyTargets) == 0 {
		return
	}

	searchDirs := []string{"/usr/local/bin", "/usr/bin"}

	for _, dir := range searchDirs {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			path := filepath.Join(dir, e.Name())
			info, err := os.Lstat(path)
			if err != nil || info.Mode()&os.ModeSymlink == 0 {
				continue
			}

			target, err := os.Readlink(path)
			if err != nil {
				continue
			}
			if !filepath.IsAbs(target) {
				target = filepath.Join(dir, target)
			}
			resolved, err := filepath.EvalSymlinks(target)
			if err != nil {
				resolved = target
			}

			if _, ok := legacyTargets[resolved]; !ok {
				continue
			}

			if err := os.Remove(path); err != nil {
				bootstrap.Warning("WARNING: Failed to remove legacy symlink %s -> %s: %v", path, resolved, err)
			} else {
				bootstrap.Info("Removed legacy bash symlink: %s -> %s", path, resolved)
			}
		}
	}
}

// ensureGoSymlink creates /usr/local/bin/proxmox-backup pointing to the current
// Go binary if there is no existing non-legacy entry.
func ensureGoSymlink(execPath string, bootstrap *logging.BootstrapLogger) {
	dest := "/usr/local/bin/proxmox-backup"
	info, err := os.Lstat(dest)
	if err == nil {
		// Something already exists: if it's a symlink we didn't remove as legacy,
		// assume it is user-managed or already pointing to Go and skip.
		if info.Mode()&os.ModeSymlink != 0 {
			bootstrap.Info("Existing symlink preserved: %s", dest)
			return
		}
		// Regular file or directory: do not overwrite.
		bootstrap.Warning("WARNING: %s already exists and is not a symlink; leaving it untouched", dest)
		return
	}
	if !os.IsNotExist(err) {
		bootstrap.Warning("WARNING: Unable to inspect %s: %v", dest, err)
		return
	}

	if err := os.Symlink(execPath, dest); err != nil {
		bootstrap.Warning("WARNING: Failed to create symlink %s -> %s: %v", dest, execPath, err)
		return
	}
	bootstrap.Info("Created symlink: %s -> %s", dest, execPath)
}

// migrateLegacyCronEntries updates root's crontab so that any entries pointing
// to the legacy bash script are migrated to the Go binary. If no cron entry for
// the backup job exists at all (neither legacy nor Go-based), it creates a
// default entry at 02:00 every day.
func migrateLegacyCronEntries(ctx context.Context, baseDir, execPath string, bootstrap *logging.BootstrapLogger) {
	baseDir = strings.TrimSpace(baseDir)
	if baseDir == "" {
		baseDir = "/opt/proxmox-backup"
	}

	// Legacy script paths that may appear in existing cron entries.
	legacyPaths := []string{
		filepath.Join(baseDir, "script", "proxmox-backup.sh"),
		filepath.Join("/opt/proxmox-backup", "script", "proxmox-backup.sh"),
	}

	newCommandToken := "/usr/local/bin/proxmox-backup"
	if _, err := os.Stat(newCommandToken); err != nil {
		fallback := strings.TrimSpace(execPath)
		if fallback != "" {
			bootstrap.Info("Symlink %s not found, falling back to %s for cron entries", newCommandToken, fallback)
			newCommandToken = fallback
		} else {
			bootstrap.Warning("WARNING: Unable to locate Go binary for cron migration")
			return
		}
	}

	// Read current root crontab via "crontab -l".
	readCron := func() (string, error) {
		cmd := exec.CommandContext(ctx, "crontab", "-l")
		output, err := cmd.CombinedOutput()
		if err != nil {
			lower := strings.ToLower(string(output))
			if strings.Contains(lower, "no crontab for") {
				// No crontab defined yet; treat as empty.
				return "", nil
			}
			return "", fmt.Errorf("crontab -l failed: %w: %s", err, strings.TrimSpace(string(output)))
		}
		return string(output), nil
	}

	writeCron := func(content string) error {
		cmd := exec.CommandContext(ctx, "crontab", "-")
		cmd.Stdin = strings.NewReader(content)
		output, err := cmd.CombinedOutput()
		if err != nil {
			return fmt.Errorf("crontab update failed: %w: %s", err, strings.TrimSpace(string(output)))
		}
		return nil
	}

	current, err := readCron()
	if err != nil {
		bootstrap.Warning("WARNING: Unable to inspect existing cron entries: %v", err)
		return
	}

	normalized := strings.ReplaceAll(current, "\r\n", "\n")
	lines := []string{}
	if strings.TrimSpace(normalized) != "" {
		lines = strings.Split(strings.TrimRight(normalized, "\n"), "\n")
	}

	updatedLines := make([]string, 0, len(lines)+1)
	legacyFound := false
	newCronExists := false

	containsLegacy := func(line string) bool {
		if strings.Contains(line, "proxmox-backup.sh") {
			return true
		}
		for _, p := range legacyPaths {
			if strings.Contains(line, p) {
				return true
			}
		}
		return false
	}

	isGoCron := func(line string) bool {
		if strings.Contains(line, newCommandToken) {
			return true
		}
		trimmed := strings.TrimSpace(line)
		if strings.Contains(trimmed, "proxmox-backup") && !strings.Contains(trimmed, "proxmox-backup.sh") {
			return true
		}
		return false
	}

	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			updatedLines = append(updatedLines, line)
			continue
		}

		if containsLegacy(line) {
			legacyFound = true
			newLine := line
			for _, p := range legacyPaths {
				newLine = strings.ReplaceAll(newLine, p, newCommandToken)
			}
			newLine = strings.ReplaceAll(newLine, "proxmox-backup.sh", "proxmox-backup")
			if isGoCron(newLine) {
				newCronExists = true
			}
			updatedLines = append(updatedLines, newLine)
			continue
		}

		if isGoCron(line) {
			newCronExists = true
		}
		updatedLines = append(updatedLines, line)
	}

	addedDefault := false
	if !legacyFound && !newCronExists {
		defaultLine := fmt.Sprintf("0 2 * * * %s", newCommandToken)
		updatedLines = append(updatedLines, defaultLine)
		addedDefault = true
	}

	// If nothing changed and we didn't add a default, no need to write.
	if !legacyFound && !addedDefault {
		return
	}

	newCron := strings.Join(updatedLines, "\n") + "\n"
	if err := writeCron(newCron); err != nil {
		bootstrap.Warning("WARNING: Failed to update cron entries: %v", err)
		return
	}

	if legacyFound {
		bootstrap.Info("Migrated legacy cron entries to use Go binary (%s)", newCommandToken)
	}
	if addedDefault {
		bootstrap.Info("Created default cron entry for Go backup at 02:00: %s", newCommandToken)
	}
}

// fetchBackupList attempts to list backups from a storage backend
// Returns nil if the backend doesn't support listing or if an error occurs
func fetchBackupList(ctx context.Context, backend storage.Storage) []*types.BackupMetadata {
	// Check if backend supports List operation
	listable, ok := backend.(interface {
		List(context.Context) ([]*types.BackupMetadata, error)
	})
	if !ok {
		return nil
	}

	backups, err := listable.List(ctx)
	if err != nil {
		return nil
	}
	return backups
}

func runEnvMigration(ctx context.Context, args *cli.Args, bootstrap *logging.BootstrapLogger) int {
	bootstrap.Println("Starting environment migration from legacy Bash backup.env")

	resolvedPath, err := resolveInstallConfigPath(args.ConfigPath)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	legacyPath, err := resolveLegacyEnvPath(ctx, args, bootstrap)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	summary, err := config.MigrateLegacyEnv(legacyPath, resolvedPath)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	bootstrap.Println("")
	bootstrap.Println("✅ Environment migration completed.")
	bootstrap.Printf("New configuration file: %s", summary.OutputPath)
	if summary.BackupPath != "" {
		bootstrap.Printf("Previous configuration backup: %s", summary.BackupPath)
	}
	if len(summary.UnmappedLegacyKeys) > 0 {
		bootstrap.Printf("Legacy keys requiring manual review (%d): %s",
			len(summary.UnmappedLegacyKeys), strings.Join(summary.UnmappedLegacyKeys, ", "))
	}
	bootstrap.Println("")
	bootstrap.Println("IMPORTANT:")
	bootstrap.Println("- Review the generated configuration manually before any production run.")
	bootstrap.Println("- Run one or more dry-run tests to validate behavior:")
	bootstrap.Println("    ./build/proxmox-backup --dry-run")
	bootstrap.Println("- Verify storage paths, retention policies, and notification settings.")
	return types.ExitSuccess.Int()
}

func runEnvMigrationDry(ctx context.Context, args *cli.Args, bootstrap *logging.BootstrapLogger) int {
	bootstrap.Println("Planning environment migration from legacy Bash backup.env (dry run)")

	resolvedPath, err := resolveInstallConfigPath(args.ConfigPath)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	legacyPath, err := resolveLegacyEnvPath(ctx, args, bootstrap)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	summary, _, err := config.PlanLegacyEnvMigration(legacyPath, resolvedPath)
	if err != nil {
		bootstrap.Error("ERROR: %v", err)
		return types.ExitConfigError.Int()
	}

	bootstrap.Printf("Target configuration file: %s", summary.OutputPath)
	printMigratedKeys(summary, bootstrap)
	printUnmappedKeys(summary, bootstrap)
	bootstrap.Println("")
	bootstrap.Println("No files were modified. Run --env-migration to apply these changes after reviewing the plan.")
	return types.ExitSuccess.Int()
}

func resolveLegacyEnvPath(ctx context.Context, args *cli.Args, bootstrap *logging.BootstrapLogger) (string, error) {
	legacyPath := strings.TrimSpace(args.LegacyEnvPath)
	if legacyPath != "" {
		if err := ensureLegacyFile(legacyPath); err != nil {
			return "", err
		}
		return legacyPath, nil
	}

	if err := ensureInteractiveStdin(); err != nil {
		return "", err
	}

	reader := bufio.NewReader(os.Stdin)
	fmt.Println()
	fmt.Println("Legacy configuration import")
	question := fmt.Sprintf("Enter the path to the legacy Bash backup.env [%s]: ", defaultLegacyEnvPath)
	for {
		fmt.Print(question)
		input, err := readLineWithContext(ctx, reader)
		if err != nil {
			return "", err
		}
		input = strings.TrimSpace(input)
		if input == "" {
			legacyPath = defaultLegacyEnvPath
		} else {
			legacyPath = input
		}
		if legacyPath == "" {
			continue
		}
		if err := ensureLegacyFile(legacyPath); err != nil {
			bootstrap.Warning("Invalid legacy configuration path: %v", err)
			continue
		}
		return legacyPath, nil
	}
}

func printMigratedKeys(summary *config.EnvMigrationSummary, bootstrap *logging.BootstrapLogger) {
	if len(summary.MigratedKeys) == 0 {
		bootstrap.Println("No legacy keys matched; template defaults will be used.")
		return
	}
	bootstrap.Println("Mapped legacy keys:")
	lines := make([]string, 0, len(summary.MigratedKeys))
	for newKey, legacyKey := range summary.MigratedKeys {
		lines = append(lines, fmt.Sprintf("%s <- %s", newKey, legacyKey))
	}
	sort.Strings(lines)
	for _, line := range lines {
		bootstrap.Printf("  %s", line)
	}
}

func printUnmappedKeys(summary *config.EnvMigrationSummary, bootstrap *logging.BootstrapLogger) {
	if len(summary.UnmappedLegacyKeys) == 0 {
		return
	}
	keys := append([]string(nil), summary.UnmappedLegacyKeys...)
	sort.Strings(keys)
	bootstrap.Printf("Legacy keys requiring manual review (%d):", len(keys))
	for _, key := range keys {
		bootstrap.Printf("  %s", key)
	}
}

func ensureLegacyFile(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("cannot stat legacy config %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("legacy config %s is a directory", path)
	}
	return nil
}

func runInstall(ctx context.Context, configPath string, bootstrap *logging.BootstrapLogger) error {
	if err := ensureInteractiveStdin(); err != nil {
		return err
	}

	resolvedPath, err := resolveInstallConfigPath(configPath)
	if err != nil {
		return err
	}
	configPath = resolvedPath

	// Derive BASE_DIR from the configuration path so that configs/, identity/, logs/, etc.
	// all live under the same root, even during --install.
	baseDir := filepath.Dir(filepath.Dir(configPath))
	if baseDir == "" || baseDir == "." || baseDir == string(filepath.Separator) {
		baseDir = "/opt/proxmox-backup"
	}
	_ = os.Setenv("BASE_DIR", baseDir)

	tmpConfigPath := configPath + ".tmp"
	defer func() {
		if _, err := os.Stat(tmpConfigPath); err == nil {
			_ = os.Remove(tmpConfigPath)
		}
	}()

	reader := bufio.NewReader(os.Stdin)
	printInstallBanner(configPath)

	template, err := prepareBaseTemplate(ctx, reader, configPath)
	if err != nil {
		return wrapInstallError(err)
	}

	if template, err = configureSecondaryStorage(ctx, reader, template); err != nil {
		return wrapInstallError(err)
	}
	if template, err = configureCloudStorage(ctx, reader, template); err != nil {
		return wrapInstallError(err)
	}
	if template, err = configureNotifications(ctx, reader, template); err != nil {
		return wrapInstallError(err)
	}
	enableEncryption, err := configureEncryption(ctx, reader, &template)
	if err != nil {
		return wrapInstallError(err)
	}

	// Ensure BASE_DIR is explicitly present in the generated env file so that
	// subsequent runs and encryption setup use the same root directory.
	template = setEnvValue(template, "BASE_DIR", baseDir)

	if err := writeConfigFile(configPath, tmpConfigPath, template); err != nil {
		return err
	}
	bootstrap.Info("✓ Configuration saved at %s", configPath)

	if err := installSupportDocs(baseDir, bootstrap); err != nil {
		return fmt.Errorf("install documentation: %w", err)
	}

	if enableEncryption {
		if err := runInitialEncryptionSetup(ctx, configPath); err != nil {
			return err
		}
	}

	// Clean up legacy bash-based symlinks that point to the old installer scripts.
	cleanupLegacyBashSymlinks(baseDir, bootstrap)

	// Ensure a proxmox-backup entry points to this Go binary, if not already customized.
	execInfo := getExecInfo()
	if execInfo.ExecPath != "" {
		ensureGoSymlink(execInfo.ExecPath, bootstrap)
	}

	// Migrate legacy cron entries pointing to the bash script to the Go binary.
	// If no cron entry exists at all, create a default one at 02:00 every day.
	if execInfo.ExecPath != "" {
		migrateLegacyCronEntries(ctx, baseDir, execInfo.ExecPath, bootstrap)
	}

	// Attempt to resolve or create a server identity so that we can show a
	// Telegram pairing code to the user (similar to the legacy installer).
	var telegramCode string
	if info, err := identity.Detect(baseDir, nil); err == nil {
		if code := strings.TrimSpace(info.ServerID); code != "" {
			telegramCode = code
		}
	}

	fmt.Println()
	fmt.Println("================================================")
	fmt.Println(" Go-based installation completed ")
	fmt.Println("================================================")
	fmt.Println()
	fmt.Println("Next steps:")
	fmt.Println("0. If you need, start migration from old backup.env:  proxmox-backup --env-migration")
	fmt.Printf("1. Edit configuration: %s\n", configPath)
	fmt.Println("2. Run first backup: proxmox-backup")
	fmt.Printf("3. Check logs: tail -f %s/log/*.log\n", baseDir)
	if telegramCode != "" {
		fmt.Printf("4. Telegram: Open @ProxmoxAN_bot and enter code: %s\n", telegramCode)
	} else {
		fmt.Println("4. Telegram: Open @ProxmoxAN_bot and enter your unique code")
	}
	fmt.Println()
	fmt.Println("\033[31mEXTRA STEP - IF YOU FIND THIS TOOL USEFUL AND WANT TO THANK ME, A COFFEE IS ALWAYS WELCOME!\033[0m")
	fmt.Println("https://buymeacoffee.com/tis24dev")
	fmt.Println()
	fmt.Println("Commands:")
	fmt.Println("  proxmox-backup     - Start backup")
	fmt.Println("  make test          - Run all tests")
	fmt.Println("  make build         - Build binary")
	fmt.Println("  --help             - Show all options")
	fmt.Println("  --dry-run          - Test without changes")
	fmt.Println("  --install          - Re-run interactive installation/setup")
	fmt.Println("  --newkey           - Generate a new encryption key for backups")
	fmt.Println("  --decrypt          - Decrypt an existing backup archive")
	fmt.Println("  --restore          - Restore data from a decrypted backup")
	fmt.Println("  --upgrade-config   - Upgrade configuration file using the embedded template (run after installing a new binary)")
	fmt.Println("  --upgrade-config-dry-run - Show differences between current configuration and the embedded template without modifying files")
	fmt.Println()

	return nil
}

func ensureInteractiveStdin() error {
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return fmt.Errorf("install wizard requires an interactive terminal (stdin is not a TTY)")
	}
	return nil
}

func resolveInstallConfigPath(configPath string) (string, error) {
	if strings.TrimSpace(configPath) == "" {
		configPath = "configs/backup.env"
	}
	if filepath.IsAbs(configPath) {
		return configPath, nil
	}
	info := getExecInfo()
	baseDir := info.BaseDir
	if baseDir == "" {
		// Fallback: parent of executable directory, then hardcoded default
		if info.ExecDir != "" {
			baseDir = filepath.Dir(info.ExecDir)
		}
		if baseDir == "" || baseDir == "." || baseDir == string(filepath.Separator) {
			baseDir = "/opt/proxmox-backup"
		}
	}
	return filepath.Join(baseDir, configPath), nil
}

func printInstallBanner(configPath string) {
	fmt.Println("===========================================")
	fmt.Println("  Proxmox Backup - Go Version")
	fmt.Printf("  Version: %s\n", version)
	if sig := buildSignature(); sig != "" {
		fmt.Printf("  Build Signature: %s\n", sig)
	}
	fmt.Println("  Mode: Install Wizard")
	fmt.Println("===========================================")
	fmt.Printf("Configuration file: %s\n\n", configPath)
}

func prepareBaseTemplate(ctx context.Context, reader *bufio.Reader, configPath string) (string, error) {
	if _, err := os.Stat(configPath); err == nil {
		overwrite, err := promptYesNo(ctx, reader, fmt.Sprintf("%s already exists. Overwrite? [y/N]: ", configPath), false)
		if err != nil {
			return "", err
		}
		if !overwrite {
			return "", fmt.Errorf("installation aborted (existing configuration kept)")
		}
	}

	create, err := promptYesNo(ctx, reader, "Generate configuration file from default template? [y/N]: ", false)
	if err != nil {
		return "", err
	}
	if !create {
		return "", fmt.Errorf("installation aborted by user")
	}

	return config.DefaultEnvTemplate(), nil
}

func configureSecondaryStorage(ctx context.Context, reader *bufio.Reader, template string) (string, error) {
	fmt.Println("\n--- Secondary storage ---")
	fmt.Println("Configure an additional local path for redundant copies. (You can change it later)")
	enableSecondary, err := promptYesNo(ctx, reader, "Enable secondary backup path? [y/N]: ", false)
	if err != nil {
		return "", err
	}
	if enableSecondary {
		secondaryPath, err := promptNonEmpty(ctx, reader, "Secondary backup path (SECONDARY_PATH): ")
		if err != nil {
			return "", err
		}
		secondaryPath = sanitizeEnvValue(secondaryPath)
		secondaryLog, err := promptNonEmpty(ctx, reader, "Secondary log path (SECONDARY_LOG_PATH): ")
		if err != nil {
			return "", err
		}
		secondaryLog = sanitizeEnvValue(secondaryLog)
		template = setEnvValue(template, "SECONDARY_ENABLED", "true")
		template = setEnvValue(template, "SECONDARY_PATH", secondaryPath)
		template = setEnvValue(template, "SECONDARY_LOG_PATH", secondaryLog)
	} else {
		template = setEnvValue(template, "SECONDARY_ENABLED", "false")
		template = setEnvValue(template, "SECONDARY_PATH", "")
		template = setEnvValue(template, "SECONDARY_LOG_PATH", "")
	}
	return template, nil
}

func configureCloudStorage(ctx context.Context, reader *bufio.Reader, template string) (string, error) {
	fmt.Println("\n--- Cloud storage (rclone) ---")
	fmt.Println("Remember to configure rclone manually before enabling cloud backups.")
	enableCloud, err := promptYesNo(ctx, reader, "Enable cloud backups? [y/N]: ", false)
	if err != nil {
		return "", err
	}
	if enableCloud {
		remote, err := promptNonEmpty(ctx, reader, "Rclone remote for backups (e.g. myremote:pbs-backups): ")
		if err != nil {
			return "", err
		}
		remote = sanitizeEnvValue(remote)
		logRemote, err := promptNonEmpty(ctx, reader, "Rclone remote for logs (e.g. myremote:/logs): ")
		if err != nil {
			return "", err
		}
		logRemote = sanitizeEnvValue(logRemote)
		template = setEnvValue(template, "CLOUD_ENABLED", "true")
		template = setEnvValue(template, "CLOUD_REMOTE", remote)
		template = setEnvValue(template, "CLOUD_LOG_PATH", logRemote)
	} else {
		template = setEnvValue(template, "CLOUD_ENABLED", "false")
		template = setEnvValue(template, "CLOUD_REMOTE", "")
		template = setEnvValue(template, "CLOUD_LOG_PATH", "")
	}
	return template, nil
}

func configureNotifications(ctx context.Context, reader *bufio.Reader, template string) (string, error) {
	fmt.Println("\n--- Telegram ---")
	enableTelegram, err := promptYesNo(ctx, reader, "Enable Telegram notifications (centralized)? [y/N]: ", false)
	if err != nil {
		return "", err
	}
	if enableTelegram {
		template = setEnvValue(template, "TELEGRAM_ENABLED", "true")
		template = setEnvValue(template, "BOT_TELEGRAM_TYPE", "centralized")
	} else {
		template = setEnvValue(template, "TELEGRAM_ENABLED", "false")
	}

	fmt.Println("\n--- Email ---")
	enableEmail, err := promptYesNo(ctx, reader, "Enable email notifications (central relay)? [y/N]: ", false)
	if err != nil {
		return "", err
	}
	if enableEmail {
		template = setEnvValue(template, "EMAIL_ENABLED", "true")
		template = setEnvValue(template, "EMAIL_DELIVERY_METHOD", "relay")
		template = setEnvValue(template, "EMAIL_FALLBACK_SENDMAIL", "true")
	} else {
		template = setEnvValue(template, "EMAIL_ENABLED", "false")
	}
	return template, nil
}

func configureEncryption(ctx context.Context, reader *bufio.Reader, template *string) (bool, error) {
	fmt.Println("\n--- Encryption ---")
	enableEncryption, err := promptYesNo(ctx, reader, "Enable backup encryption? [y/N]: ", false)
	if err != nil {
		return false, err
	}
	if enableEncryption {
		*template = setEnvValue(*template, "ENCRYPT_ARCHIVE", "true")
	} else {
		*template = setEnvValue(*template, "ENCRYPT_ARCHIVE", "false")
	}
	return enableEncryption, nil
}

func writeConfigFile(configPath, tmpConfigPath, content string) error {
	dir := filepath.Dir(configPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("failed to create configuration directory: %w", err)
	}
	if err := os.WriteFile(tmpConfigPath, []byte(content), 0o600); err != nil {
		return fmt.Errorf("failed to write configuration file: %w", err)
	}
	if err := os.Rename(tmpConfigPath, configPath); err != nil {
		return fmt.Errorf("failed to finalize configuration file: %w", err)
	}
	return nil
}

func runInitialEncryptionSetup(ctx context.Context, configPath string) error {
	cfg, err := config.LoadConfig(configPath)
	if err != nil {
		return fmt.Errorf("failed to reload configuration after install: %w", err)
	}
	logger := logging.New(types.LogLevelError, false)
	logger.SetOutput(io.Discard)
	orch := orchestrator.New(logger, "/opt/proxmox-backup/script", false)
	orch.SetConfig(cfg)
	if err := orch.EnsureAgeRecipientsReady(ctx); err != nil {
		if errors.Is(err, orchestrator.ErrAgeRecipientSetupAborted) {
			return fmt.Errorf("encryption setup aborted by user")
		}
		return fmt.Errorf("encryption setup failed: %w", err)
	}
	return nil
}

func wrapInstallError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, errInteractiveAborted) {
		return fmt.Errorf("installation aborted by user")
	}
	return err
}

func promptYesNo(ctx context.Context, reader *bufio.Reader, question string, defaultYes bool) (bool, error) {
	for {
		if err := ctx.Err(); err != nil {
			return false, errInteractiveAborted
		}
		fmt.Print(question)
		resp, err := readLineWithContext(ctx, reader)
		if err != nil {
			return false, err
		}
		resp = strings.TrimSpace(strings.ToLower(resp))
		if resp == "" {
			return defaultYes, nil
		}
		switch resp {
		case "y", "yes":
			return true, nil
		case "n", "no":
			return false, nil
		default:
			fmt.Println("Please answer with 'y' or 'n'.")
		}
	}
}

func promptNonEmpty(ctx context.Context, reader *bufio.Reader, question string) (string, error) {
	for {
		if err := ctx.Err(); err != nil {
			return "", errInteractiveAborted
		}
		fmt.Print(question)
		resp, err := readLineWithContext(ctx, reader)
		if err != nil {
			return "", err
		}
		resp = strings.TrimSpace(resp)
		if resp != "" {
			return resp, nil
		}
		fmt.Println("Value cannot be empty.")
	}
}

var (
	errInteractiveAborted = errors.New("interactive input aborted")
	errPromptInputClosed  = errors.New("stdin closed")
)

func readLineWithContext(ctx context.Context, reader *bufio.Reader) (string, error) {
	type result struct {
		line string
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		line, err := reader.ReadString('\n')
		ch <- result{line: line, err: mapPromptInputError(err)}
	}()
	select {
	case <-ctx.Done():
		return "", errInteractiveAborted
	case res := <-ch:
		if res.err != nil {
			if errors.Is(res.err, errPromptInputClosed) {
				return "", errInteractiveAborted
			}
			return "", res.err
		}
		return res.line, nil
	}
}

func mapPromptInputError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, io.EOF) {
		return errPromptInputClosed
	}
	errStr := strings.ToLower(err.Error())
	if strings.Contains(errStr, "use of closed file") ||
		strings.Contains(errStr, "bad file descriptor") ||
		strings.Contains(errStr, "file already closed") {
		return errPromptInputClosed
	}
	return err
}

func setEnvValue(template, key, value string) string {
	target := key + "="
	lines := strings.Split(template, "\n")
	replaced := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, target) {
			leadingLen := len(line) - len(strings.TrimLeft(line, " \t"))
			leading := ""
			if leadingLen > 0 {
				leading = line[:leadingLen]
			}
			rest := line[leadingLen:]
			commentSpacing := ""
			comment := ""
			if idx := strings.Index(rest, "#"); idx >= 0 {
				before := rest[:idx]
				comment = rest[idx:]
				trimmedBefore := strings.TrimRight(before, " \t")
				commentSpacing = before[len(trimmedBefore):]
				rest = trimmedBefore
			}
			newLine := leading + key + "=" + value
			if comment != "" {
				spacing := commentSpacing
				if spacing == "" {
					spacing = " "
				}
				newLine += spacing + comment
			}
			lines[i] = newLine
			replaced = true
		}
	}
	if !replaced {
		lines = append(lines, key+"="+value)
	}
	return strings.Join(lines, "\n")
}

func sanitizeEnvValue(value string) string {
	value = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\x00' {
			return -1
		}
		return r
	}, value)
	return strings.TrimSpace(value)
}

func buildSignature() string {
	hash := executableHash()
	formattedTime := ""

	// Priority 1: Use injected buildTime (actual build timestamp)
	actualBuildTime := executableBuildTime()
	if !actualBuildTime.IsZero() {
		formattedTime = actualBuildTime.Local().Format(time.RFC3339)
	}

	var revision string
	modified := ""

	if info, ok := debug.ReadBuildInfo(); ok {
		for _, setting := range info.Settings {
			switch setting.Key {
			case "vcs.revision":
				revision = setting.Value
			case "vcs.modified":
				if setting.Value == "true" {
					modified = "*"
				}
			}
		}
		if revision != "" {
			shortRev := revision
			if len(shortRev) > 9 {
				shortRev = shortRev[:9]
			}
			sig := shortRev + modified
			if formattedTime != "" {
				sig = fmt.Sprintf("%s (%s)", sig, formattedTime)
			}
			if hash != "" {
				sig = fmt.Sprintf("%s hash=%s", sig, truncateHash(hash))
			}
			return sig
		}
	}

	// Fallback: only timestamp and hash
	if formattedTime != "" && hash != "" {
		return fmt.Sprintf("%s hash=%s", formattedTime, truncateHash(hash))
	}
	if formattedTime != "" {
		return formattedTime
	}
	if hash != "" {
		return fmt.Sprintf("hash=%s", truncateHash(hash))
	}
	return ""
}

func executableBuildTime() time.Time {
	// If buildTime was injected at compile time, use it
	if buildTime != "" {
		if t, err := time.Parse(time.RFC3339, buildTime); err == nil {
			return t
		}
	}

	// Fallback: use file modification time (current behavior)
	info := getExecInfo()
	if info.ExecPath == "" {
		return time.Time{}
	}
	stat, err := os.Stat(info.ExecPath)
	if err != nil {
		return time.Time{}
	}
	return stat.ModTime()
}

func executableHash() string {
	info := getExecInfo()
	if info.ExecPath == "" {
		return ""
	}
	f, err := os.Open(info.ExecPath)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

func truncateHash(hash string) string {
	if len(hash) <= 16 {
		return hash
	}
	return hash[:16]
}

func cleanupAfterRun(logger *logging.Logger) {
	patterns := []string{
		"/tmp/backup_status_update_*.lock",
		"/tmp/backup_*_*.lock",
	}

	for _, pattern := range patterns {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			logger.Debug("Cleanup glob error for %s: %v", pattern, err)
			continue
		}

		for _, match := range matches {
			info, err := os.Stat(match)
			if err != nil {
				continue
			}
			if info.Size() != 0 {
				continue
			}
			if err := os.Remove(match); err != nil {
				logger.Warning("Failed to remove orphaned lock file %s: %v", match, err)
			} else {
				logger.Debug("Removed orphaned lock file: %s", match)
			}
		}
	}
}

func addPathExclusion(excludes []string, path string) []string {
	clean := filepath.Clean(strings.TrimSpace(path))
	if clean == "" {
		return excludes
	}
	excludes = append(excludes, clean)
	excludes = append(excludes, filepath.ToSlash(filepath.Join(clean, "**")))
	return excludes
}

func isLocalPath(path string) bool {
	clean := strings.TrimSpace(path)
	if clean == "" {
		return false
	}
	if strings.Contains(clean, ":") && !strings.HasPrefix(clean, "/") {
		// Likely an rclone remote (remote:bucket)
		return false
	}
	return filepath.IsAbs(clean)
}
