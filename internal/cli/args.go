package cli

import (
	"flag"
	"fmt"
	"os"

	"github.com/tis24dev/proxmox-backup/internal/types"
)

// Args holds the parsed command-line arguments
type Args struct {
	ConfigPath       string
	ConfigPathSource string
	LogLevel         types.LogLevel
	DryRun           bool
	ShowVersion      bool
	ShowHelp         bool
	ForceNewKey      bool
	Decrypt          bool
	Restore          bool
	Install          bool
	UpgradeConfig    bool
	UpgradeConfigDry bool
	EnvMigration     bool
	EnvMigrationDry  bool
	LegacyEnvPath    string
}

// Parse parses command-line arguments and returns Args struct
func Parse() *Args {
	args := &Args{}

	const defaultConfigPath = "./configs/backup.env"
	configFlag := newStringFlag(defaultConfigPath)

	// Define flags
	flag.Var(configFlag, "config", "Path to configuration file")
	flag.Var(configFlag, "c", "Path to configuration file (shorthand)")

	var logLevelStr string
	flag.StringVar(&logLevelStr, "log-level", "",
		"Log level (debug|info|warning|error|critical)")
	flag.StringVar(&logLevelStr, "l", "",
		"Log level (shorthand)")

	flag.BoolVar(&args.DryRun, "dry-run", false,
		"Perform a dry run without making actual changes")
	flag.BoolVar(&args.DryRun, "n", false,
		"Perform a dry run (shorthand)")

	flag.BoolVar(&args.ShowVersion, "version", false,
		"Show version information")
	flag.BoolVar(&args.ShowVersion, "v", false,
		"Show version information (shorthand)")

	flag.BoolVar(&args.ShowHelp, "help", false,
		"Show help message")
	flag.BoolVar(&args.ShowHelp, "h", false,
		"Show help message (shorthand)")

	flag.BoolVar(&args.ForceNewKey, "newkey", false,
		"Reset AGE recipients and run the interactive setup (interactive mode only)")
	flag.BoolVar(&args.ForceNewKey, "age-newkey", false,
		"Alias for --newkey")

	flag.BoolVar(&args.Decrypt, "decrypt", false,
		"Run the interactive decrypt workflow (converts encrypted bundles into plaintext bundles)")
	flag.BoolVar(&args.Restore, "restore", false,
		"Run the interactive restore workflow (select bundle, optionally decrypt, apply to system)")
	flag.BoolVar(&args.Install, "install", false,
		"Run the interactive installer (generate/configure backup.env)")
	flag.BoolVar(&args.EnvMigration, "env-migration", false,
		"Run the installer and migrate a legacy Bash backup.env to the Go template")
	flag.BoolVar(&args.EnvMigrationDry, "env-migration-dry-run", false,
		"Preview the installer + legacy env migration without writing files")
	flag.StringVar(&args.LegacyEnvPath, "old-env", "",
		"Path to the legacy Bash backup.env used during --env-migration")

	flag.BoolVar(&args.UpgradeConfig, "upgrade-config", false,
		"Upgrade configuration file using the embedded template (adds missing keys, preserves existing and custom keys)")

	flag.BoolVar(&args.UpgradeConfigDry, "upgrade-config-dry-run", false,
		"Plan configuration upgrade using the embedded template without modifying the file (reports missing and custom keys)")

	// Custom usage message
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage: %s [options]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Proxmox Backup Manager - Go Edition\n\n")
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  %s -c /path/to/config.env\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s --dry-run --log-level debug\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s --version\n", os.Args[0])
	}

	// Parse flags
	flag.Parse()

	args.ConfigPath = configFlag.value
	if configFlag.set {
		args.ConfigPathSource = "specified via --config/-c flag"
	} else {
		args.ConfigPathSource = "default path"
	}

	// Parse log level if provided
	if logLevelStr != "" {
		args.LogLevel = parseLogLevel(logLevelStr)
	} else {
		args.LogLevel = types.LogLevelNone // Will be overridden by config
	}

	return args
}

// parseLogLevel converts string to LogLevel
func parseLogLevel(s string) types.LogLevel {
	switch s {
	case "debug", "5":
		return types.LogLevelDebug
	case "info", "4":
		return types.LogLevelInfo
	case "warning", "3":
		return types.LogLevelWarning
	case "error", "2":
		return types.LogLevelError
	case "critical", "1":
		return types.LogLevelCritical
	case "none", "0":
		return types.LogLevelNone
	default:
		return types.LogLevelInfo
	}
}

// ShowHelp displays help message and exits
func ShowHelp() {
	flag.Usage()
	os.Exit(0)
}

// ShowVersion displays version information and exits
func ShowVersion() {
	fmt.Printf("Proxmox Backup Manager (Go Edition)\n")
	fmt.Printf("Version: 0.2.0-dev\n")
	fmt.Printf("Build: development\n")
	fmt.Printf("Author: tis24dev\n")
	os.Exit(0)
}

type stringFlag struct {
	value string
	set   bool
}

func newStringFlag(defaultValue string) *stringFlag {
	return &stringFlag{value: defaultValue}
}

func (s *stringFlag) String() string {
	return s.value
}

func (s *stringFlag) Set(val string) error {
	s.value = val
	s.set = true
	return nil
}
