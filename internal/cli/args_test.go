package cli

import (
	"testing"

	"github.com/tis24dev/proxmox-backup/internal/types"
)

func TestParseLogLevel(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected types.LogLevel
	}{
		{"debug string", "debug", types.LogLevelDebug},
		{"debug number", "5", types.LogLevelDebug},
		{"info string", "info", types.LogLevelInfo},
		{"info number", "4", types.LogLevelInfo},
		{"warning string", "warning", types.LogLevelWarning},
		{"warning number", "3", types.LogLevelWarning},
		{"error string", "error", types.LogLevelError},
		{"error number", "2", types.LogLevelError},
		{"critical string", "critical", types.LogLevelCritical},
		{"critical number", "1", types.LogLevelCritical},
		{"none string", "none", types.LogLevelNone},
		{"none number", "0", types.LogLevelNone},
		{"unknown", "invalid", types.LogLevelInfo}, // defaults to info
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseLogLevel(tt.input)
			if result != tt.expected {
				t.Errorf("parseLogLevel(%q) = %v; want %v", tt.input, result, tt.expected)
			}
		})
	}
}

// Note: Due to limitations with the flag package, we cannot easily test Parse()
// multiple times in the same test run. The flag package maintains global state
// that cannot be easily reset. These tests verify the internal logic without
// calling Parse() multiple times.

func TestArgs(t *testing.T) {
	// Test Args struct creation
	args := &Args{
		ConfigPath:  "/test/path.env",
		LogLevel:    types.LogLevelDebug,
		DryRun:      true,
		ShowVersion: false,
		ShowHelp:    false,
	}

	if args.ConfigPath != "/test/path.env" {
		t.Errorf("ConfigPath = %q; want %q", args.ConfigPath, "/test/path.env")
	}

	if args.LogLevel != types.LogLevelDebug {
		t.Errorf("LogLevel = %v; want %v", args.LogLevel, types.LogLevelDebug)
	}

	if !args.DryRun {
		t.Error("DryRun should be true")
	}

	if args.ShowVersion {
		t.Error("ShowVersion should be false")
	}

	if args.ShowHelp {
		t.Error("ShowHelp should be false")
	}
}
