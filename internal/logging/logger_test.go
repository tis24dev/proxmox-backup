package logging

import (
	"bytes"
	"strings"
	"testing"

	"github.com/tis24dev/proxmox-backup/internal/types"
)

func TestNew(t *testing.T) {
	logger := New(types.LogLevelInfo, true)

	if logger.level != types.LogLevelInfo {
		t.Errorf("Expected level %v, got %v", types.LogLevelInfo, logger.level)
	}

	if !logger.useColor {
		t.Error("Expected useColor to be true")
	}

	if logger.output == nil {
		t.Error("Expected output to be set")
	}
}

func TestSetLevel(t *testing.T) {
	logger := New(types.LogLevelInfo, false)

	logger.SetLevel(types.LogLevelDebug)

	if logger.GetLevel() != types.LogLevelDebug {
		t.Errorf("Expected level %v, got %v", types.LogLevelDebug, logger.GetLevel())
	}
}

func TestLogLevelFiltering(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelWarning, false)
	logger.SetOutput(&buf)

	// These should not appear (below warning level)
	logger.Debug("debug message")
	logger.Info("info message")

	// These should appear
	logger.Warning("warning message")
	logger.Error("error message")
	logger.Critical("critical message")

	output := buf.String()

	// Debug and Info should not be in output
	if strings.Contains(output, "debug message") {
		t.Error("Debug message should not appear when level is WARNING")
	}
	if strings.Contains(output, "info message") {
		t.Error("Info message should not appear when level is WARNING")
	}

	// Warning, Error, Critical should be in output
	if !strings.Contains(output, "warning message") {
		t.Error("Warning message should appear")
	}
	if !strings.Contains(output, "error message") {
		t.Error("Error message should appear")
	}
	if !strings.Contains(output, "critical message") {
		t.Error("Critical message should appear")
	}
}

func TestLogFormatting(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelInfo, false)
	logger.SetOutput(&buf)

	logger.Info("test message")

	output := buf.String()

	// Check that output contains expected parts
	if !strings.Contains(output, "INFO") {
		t.Error("Output should contain log level INFO")
	}
	if !strings.Contains(output, "test message") {
		t.Error("Output should contain the message")
	}
	// Check for timestamp (format: YYYY-MM-DD HH:MM:SS)
	if !strings.Contains(output, "[") || !strings.Contains(output, "]") {
		t.Error("Output should contain timestamp in brackets")
	}
}

func TestPhaseLogging(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelInfo, false)
	logger.SetOutput(&buf)

	logger.Phase("Phase message")

	output := buf.String()

	if !strings.Contains(output, "PHASE") {
		t.Error("Output should contain level PHASE")
	}
	if !strings.Contains(output, "Phase message") {
		t.Error("Output should contain the phase message")
	}
}

func TestLogWithFormatting(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelInfo, false)
	logger.SetOutput(&buf)

	logger.Info("Number: %d, String: %s", 42, "test")

	output := buf.String()

	if !strings.Contains(output, "Number: 42") {
		t.Error("Output should contain formatted number")
	}
	if !strings.Contains(output, "String: test") {
		t.Error("Output should contain formatted string")
	}
}

func TestColorOutput(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelInfo, true) // with colors
	logger.SetOutput(&buf)

	logger.Info("test")

	output := buf.String()

	// Should contain ANSI color codes
	if !strings.Contains(output, "\033[") {
		t.Error("Colored output should contain ANSI codes")
	}
}

func TestNoColorOutput(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelInfo, false) // without colors
	logger.SetOutput(&buf)

	logger.Info("test")

	output := buf.String()

	// Should NOT contain ANSI color codes
	if strings.Contains(output, "\033[") {
		t.Error("Non-colored output should not contain ANSI codes")
	}
}

func TestDifferentLogLevels(t *testing.T) {
	var buf bytes.Buffer
	logger := New(types.LogLevelDebug, false)
	logger.SetOutput(&buf)

	tests := []struct {
		name     string
		logFunc  func(string, ...interface{})
		message  string
		levelStr string
	}{
		{"debug", logger.Debug, "debug test", "DEBUG"},
		{"info", logger.Info, "info test", "INFO"},
		{"warning", logger.Warning, "warning test", "WARNING"},
		{"error", logger.Error, "error test", "ERROR"},
		{"critical", logger.Critical, "critical test", "CRITICAL"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			buf.Reset()
			tt.logFunc(tt.message)
			output := buf.String()

			if !strings.Contains(output, tt.levelStr) {
				t.Errorf("Output should contain level %s", tt.levelStr)
			}
			if !strings.Contains(output, tt.message) {
				t.Errorf("Output should contain message %s", tt.message)
			}
		})
	}
}

func TestDefaultLogger(t *testing.T) {
	// Test that default logger exists
	defaultLog := GetDefaultLogger()
	if defaultLog == nil {
		t.Fatal("Default logger should not be nil")
	}

	// Test setting custom default logger
	customLogger := New(types.LogLevelDebug, false)
	SetDefaultLogger(customLogger)

	if GetDefaultLogger() != customLogger {
		t.Error("GetDefaultLogger should return the custom logger")
	}
}

func TestPackageLevelFunctions(t *testing.T) {
	var buf bytes.Buffer
	customLogger := New(types.LogLevelDebug, false)
	customLogger.SetOutput(&buf)
	SetDefaultLogger(customLogger)

	// Test package-level functions
	Debug("debug")
	Info("info")
	Warning("warning")
	Error("error")
	Critical("critical")

	output := buf.String()

	levels := []string{"DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"}
	for _, level := range levels {
		if !strings.Contains(output, level) {
			t.Errorf("Output should contain %s", level)
		}
	}
}
