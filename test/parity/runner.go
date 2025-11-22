package parity

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"time"
)

// TestResult holds the result of a parity test
type TestResult struct {
	Name       string
	BashExitCode int
	GoExitCode   int
	BashOutput   string
	GoOutput     string
	BashDuration time.Duration
	GoDuration   time.Duration
	Passed       bool
	Error        error
}

// Runner executes parity tests between Bash and Go implementations
type Runner struct {
	bashScriptPath string
	goBinaryPath   string
	configPath     string
}

// NewRunner creates a new parity test runner
func NewRunner(bashScriptPath, goBinaryPath, configPath string) *Runner {
	return &Runner{
		bashScriptPath: bashScriptPath,
		goBinaryPath:   goBinaryPath,
		configPath:     configPath,
	}
}

// RunDryRunTest runs both implementations in dry-run mode and compares results
func (r *Runner) RunDryRunTest(ctx context.Context, testName string) *TestResult {
	result := &TestResult{
		Name: testName,
	}

	// Run Bash version
	bashStart := time.Now()
	bashOut, bashErr := r.runBash(ctx, "--dry-run")
	result.BashDuration = time.Since(bashStart)
	if bashErr != nil {
		if exitErr, ok := bashErr.(*exec.ExitError); ok {
			result.BashExitCode = exitErr.ExitCode()
		} else {
			result.BashExitCode = 1
			result.Error = fmt.Errorf("bash execution failed: %w", bashErr)
		}
	}
	result.BashOutput = bashOut

	// Run Go version
	goStart := time.Now()
	goOut, goErr := r.runGo(ctx, "--dry-run")
	result.GoDuration = time.Since(goStart)
	if goErr != nil {
		if exitErr, ok := goErr.(*exec.ExitError); ok {
			result.GoExitCode = exitErr.ExitCode()
		} else {
			result.GoExitCode = 1
			if result.Error == nil {
				result.Error = fmt.Errorf("go execution failed: %w", goErr)
			}
		}
	}
	result.GoOutput = goOut

	// Compare exit codes
	result.Passed = result.BashExitCode == result.GoExitCode

	return result
}

// runBash executes the Bash script
func (r *Runner) runBash(ctx context.Context, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "/bin/bash", append([]string{r.bashScriptPath}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.String(), err
}

// runGo executes the Go binary
func (r *Runner) runGo(ctx context.Context, args ...string) (string, error) {
	allArgs := append([]string{"--config", r.configPath}, args...)
	cmd := exec.CommandContext(ctx, r.goBinaryPath, allArgs...)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	return out.String(), err
}

// Report generates a comparison report
func (r *TestResult) Report() string {
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "=== Parity Test: %s ===\n", r.Name)
	fmt.Fprintf(&buf, "Bash Exit Code: %d\n", r.BashExitCode)
	fmt.Fprintf(&buf, "Go   Exit Code: %d\n", r.GoExitCode)
	fmt.Fprintf(&buf, "Bash Duration:  %v\n", r.BashDuration)
	fmt.Fprintf(&buf, "Go   Duration:  %v\n", r.GoDuration)
	if r.Passed {
		fmt.Fprintf(&buf, "Status: PASSED ✓\n")
	} else {
		fmt.Fprintf(&buf, "Status: FAILED ✗\n")
	}
	if r.Error != nil {
		fmt.Fprintf(&buf, "Error: %v\n", r.Error)
	}
	fmt.Fprintf(&buf, "\n")
	return buf.String()
}
