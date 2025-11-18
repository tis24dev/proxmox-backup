package security

import (
	"fmt"
	"io"
	"strings"
	"testing"

	"github.com/tis24dev/proxmox-backup/internal/config"
	"github.com/tis24dev/proxmox-backup/internal/logging"
	"github.com/tis24dev/proxmox-backup/internal/types"
)

func newSecurityTestLogger() *logging.Logger {
	logger := logging.New(types.LogLevelDebug, false)
	logger.SetOutput(io.Discard)
	return logger
}

func newCheckerForTest(cfg *config.Config, lookPath func(string) (string, error)) *Checker {
	return &Checker{
		logger:   newSecurityTestLogger(),
		cfg:      cfg,
		result:   &Result{},
		lookPath: lookPath,
	}
}

func stubLookPath(existing map[string]bool) func(string) (string, error) {
	return func(binary string) (string, error) {
		if existing[binary] {
			return "/usr/bin/" + binary, nil
		}
		return "", fmt.Errorf("not found")
	}
}

func TestCheckDependenciesMissingRequiredAddsError(t *testing.T) {
	cfg := &config.Config{
		CompressionType: types.CompressionXZ, // requires xz binary in addition to tar
	}
	checker := newCheckerForTest(cfg, stubLookPath(map[string]bool{
		"tar": true, // present
		// "xz" missing
	}))

	checker.checkDependencies()

	if got := checker.result.ErrorCount(); got != 1 {
		t.Fatalf("expected 1 error, got %d issues=%+v", got, checker.result.Issues)
	}
	msg := checker.result.Issues[0].Message
	if !strings.Contains(msg, "Required dependency") || !strings.Contains(msg, "xz") {
		t.Fatalf("unexpected issue message: %s", msg)
	}
}

func TestCheckDependenciesMissingOptionalAddsWarning(t *testing.T) {
	cfg := &config.Config{
		CompressionType:       types.CompressionNone, // only tar required
		EmailDeliveryMethod:   "relay",
		EmailFallbackSendmail: true, // sendmail becomes optional dependency
	}
	checker := newCheckerForTest(cfg, stubLookPath(map[string]bool{
		"tar": true, // present
		// sendmail missing -> warning
	}))

	checker.checkDependencies()

	if got := checker.result.WarningCount(); got != 1 {
		t.Fatalf("expected 1 warning, got %d issues=%+v", got, checker.result.Issues)
	}
	msg := checker.result.Issues[0].Message
	if !strings.Contains(msg, "Optional dependency") || !strings.Contains(msg, "sendmail") {
		t.Fatalf("unexpected warning message: %s", msg)
	}
	if checker.result.ErrorCount() != 0 {
		t.Fatalf("expected no errors, got %d", checker.result.ErrorCount())
	}
}
