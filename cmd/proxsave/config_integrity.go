package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/tis24dev/proxsave/internal/config"
	"github.com/tis24dev/proxsave/internal/logging"
)

// integrityFindingIndent aligns a finding under the block title. The verdict is
// deliberately NOT indented: it is the conclusion of the block, not one more
// finding inside it.
const integrityFindingIndent = "  "

var configIntegrityAuditor = config.AuditConfigFile

// auditRunConfigFile is the "Configuration integrity check" block, run once per run
// immediately after the configuration is loaded and BEFORE the effective settings are
// printed. The order is the point: a discarded value has to be reported before the
// recap that would otherwise show the surviving one as if nothing were lost.
//
// Levels carry the difference between the three findings, which are not the same fact:
//   - duplicated: a value the operator wrote is discarded by the loader's last-wins
//     rule, so it is a WARNING;
//   - absent: the binary carries the variable in its embedded template but the file
//     does not, which can only mean the configuration merge never ran, so it is a
//     WARNING too. An operator who has NOT upgraded runs an older binary with an older
//     template and sees nothing here;
//   - unknown: a variable the binary does not read. Nothing the operator wrote is lost
//     by the loader, it was never picked up in the first place, so it is INFO.
//
// The raw counters go to DEBUG BEFORE the operator-facing lines, because the audit
// knows the numbers before it renders them.
func auditRunConfigFile(rt *appRuntime) {
	if rt == nil || rt.bootstrap == nil {
		return
	}
	path := ""
	if rt.cfg != nil {
		path = strings.TrimSpace(rt.cfg.ConfigPath)
	}
	if path == "" && rt.args != nil {
		path = strings.TrimSpace(rt.args.ConfigPath)
	}
	if path == "" {
		return
	}

	started := time.Now()
	report, err := configIntegrityAuditor(path)
	if err != nil {
		// A file the loader has just read successfully cannot normally fail here, so
		// say so rather than staying silent: a silent block reads as "all clear".
		rt.bootstrap.Warning("Configuration integrity check could not run: %v", err)
		return
	}
	renderConfigIntegrityReport(rt.bootstrap, report, time.Since(started))
}

func renderConfigIntegrityReport(bootstrap *logging.BootstrapLogger, report *config.ConfigIntegrityReport, elapsed time.Duration) {
	if bootstrap == nil || report == nil {
		return
	}
	bootstrap.Info("Configuration integrity check:")
	bootstrap.Debug("Configuration integrity: file=%s lines=%d assignments=%d distinct=%d template=%d",
		report.Path, report.Lines, report.Assignments, report.Distinct, report.TemplateVariables)
	if len(report.SkippedMultiValue) > 0 {
		bootstrap.Debug("Configuration integrity: multi-value variables skipped: %s",
			strings.Join(report.SkippedMultiValue, ", "))
	}
	for _, duplicated := range report.Duplicated {
		bootstrap.Debug("Configuration integrity: %s assigned on lines %s; last assignment wins",
			duplicated.Name, joinLineNumbers(duplicated.Lines))
	}
	for _, name := range report.Absent {
		bootstrap.Debug("Configuration integrity: %s present in embedded template, absent from file", name)
	}
	for _, name := range report.Unknown {
		bootstrap.Debug("Configuration integrity: %s assigned in file, absent from embedded template", name)
	}

	for _, duplicated := range report.Duplicated {
		bootstrap.Warning("%s%s", integrityFindingIndent, duplicatedVariableSentence(duplicated))
	}
	for _, name := range report.Absent {
		bootstrap.Warning("%s%s is absent and falls back to its default", integrityFindingIndent, name)
	}
	for _, name := range report.Unknown {
		bootstrap.Info("%s%s is not a known variable and is ignored", integrityFindingIndent, name)
	}

	bootstrap.Debug("Configuration integrity: %d duplicated, %d absent, %d unknown (duration=%s)",
		len(report.Duplicated), len(report.Absent), len(report.Unknown), elapsed.Round(100*time.Microsecond))
	if report.HasIssues() {
		bootstrap.Warning("⚠ Configuration file: %s", integrityVerdictCounts(report))
		return
	}
	if report.Clean() {
		bootstrap.Info("✓ Configuration file ok")
		return
	}
	// Green, but not silent: an unknown variable is reported without pretending the
	// file is untouched, because the operator wrote a line the binary never reads.
	bootstrap.Info("✓ Configuration file ok (%s)", integrityVerdictCounts(report))
}

// duplicatedVariableSentence names the winner and every discarded line, never the
// values: a duplicated TELEGRAM_BOT_TOKEN would otherwise print a secret.
func duplicatedVariableSentence(duplicated config.DuplicatedVariable) string {
	discarded := duplicated.Lines[:len(duplicated.Lines)-1]
	if len(duplicated.Lines) == 2 {
		return fmt.Sprintf("%s is set twice; line %d wins and the value on line %d is discarded",
			duplicated.Name, duplicated.WinningLine, discarded[0])
	}
	return fmt.Sprintf("%s is set %d times; line %d wins and the values on lines %s are discarded",
		duplicated.Name, len(duplicated.Lines), duplicated.WinningLine, joinLineNumbers(discarded))
}

// integrityVerdictCounts lists only the categories that actually fired, so the verdict
// never spends a word on a category that found nothing.
func integrityVerdictCounts(report *config.ConfigIntegrityReport) string {
	parts := make([]string, 0, 3)
	if n := len(report.Duplicated); n > 0 {
		parts = append(parts, fmt.Sprintf("%d duplicated", n))
	}
	if n := len(report.Absent); n > 0 {
		parts = append(parts, fmt.Sprintf("%d absent", n))
	}
	if n := len(report.Unknown); n > 0 {
		parts = append(parts, fmt.Sprintf("%d unknown", n))
	}
	if len(parts) == 0 {
		return "no duplicated, absent or unknown variable"
	}
	return strings.Join(parts, ", ")
}

func joinLineNumbers(lines []int) string {
	parts := make([]string, 0, len(lines))
	for _, line := range lines {
		parts = append(parts, strconv.Itoa(line))
	}
	return strings.Join(parts, ", ")
}
