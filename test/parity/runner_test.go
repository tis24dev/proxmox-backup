package parity

import (
	"context"
	"os"
	"testing"
	"time"
)

// TestParityDryRun is a basic parity test that runs both implementations in dry-run mode
// This test is skipped by default and only runs when explicitly requested
func TestParityDryRun(t *testing.T) {
	if os.Getenv("PARITY") != "1" {
		t.Skip("Parity tests disabled (set PARITY=1 to enable)")
	}

	if testing.Short() {
		t.Skip("Skipping parity test in short mode")
	}

	// These paths would need to be configured based on the actual environment
	bashScript := "/opt/proxmox-backup/script/proxmox-backup.sh"
	goBinary := "/opt/proxmox-backup-go/build/proxmox-backup"
	config := "/opt/proxmox-backup/env/backup.env"

	runner := NewRunner(bashScript, goBinary, config)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	result := runner.RunDryRunTest(ctx, "dry-run-basic")

	t.Log(result.Report())

	if !result.Passed {
		t.Errorf("Parity test failed: exit codes don't match (Bash: %d, Go: %d)",
			result.BashExitCode, result.GoExitCode)
	}

	if result.Error != nil {
		t.Logf("Note: Test completed with error: %v", result.Error)
	}
}

// TestParityExitCodes tests that exit codes match for various scenarios
func TestParityExitCodes(t *testing.T) {
	if os.Getenv("PARITY") != "1" {
		t.Skip("Parity tests disabled (set PARITY=1 to enable)")
	}

	if testing.Short() {
		t.Skip("Skipping parity test in short mode")
	}

	// Placeholder for future exit code parity tests
	// This would test scenarios like:
	// - Invalid config path
	// - Missing permissions
	// - etc.
	t.Skip("Exit code parity tests not yet implemented")
}
