package config

import (
	"bufio"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/tis24dev/proxsave/pkg/utils"
)

// DuplicatedVariable records one variable assigned more than once in backup.env.
//
// Lines holds every assignment line in file order; WinningLine is the last one,
// because parseEnvFile writes raw[upperKey] on every hit and the last write wins.
// The discarded values are deliberately NOT recorded: a duplicated
// TELEGRAM_BOT_TOKEN would put a secret in the log, and the line number is
// enough for the operator to find it.
type DuplicatedVariable struct {
	Name        string
	Lines       []int
	WinningLine int
}

// ConfigIntegrityReport is the verdict of one audit of a backup.env against the
// embedded template. It carries the raw counters the DEBUG lines print and the
// three finding sets the operator-facing lines print, so every surface renders
// the same audit instead of recomputing it.
type ConfigIntegrityReport struct {
	Path              string
	Lines             int
	Assignments       int
	Distinct          int
	TemplateVariables int
	SkippedMultiValue []string
	Duplicated        []DuplicatedVariable
	Absent            []string
	Unknown           []string
}

// Clean reports whether the audit found nothing at all.
func (r *ConfigIntegrityReport) Clean() bool {
	if r == nil {
		return true
	}
	return len(r.Duplicated) == 0 && len(r.Absent) == 0 && len(r.Unknown) == 0
}

// HasIssues reports whether the audit found something that discards or omits an
// operator value. An unknown variable is deliberately excluded: it is reported,
// but it is not evidence that anything the operator wrote is being lost.
func (r *ConfigIntegrityReport) HasIssues() bool {
	if r == nil {
		return false
	}
	return len(r.Duplicated) > 0 || len(r.Absent) > 0
}

// AuditConfigFile compares an env file against the embedded template.
//
// It deliberately does NOT change parseEnvFile, whose upstream blast radius is the
// whole install/upgrade surface. It re-reads the file with the same primitives
// instead - utils.IsComment, utils.SplitKeyValue, the same "export" prefix rule and
// the same multiValueKeys/blockValueKeys sets - so the two readers agree by
// construction rather than by coincidence. TestAuditAgreesWithTheLoader pins that.
//
// Nothing here rejects a configuration or changes which value wins. Last-wins stays
// the loader's rule; the audit only stops it from being silent.
func AuditConfigFile(path string) (*ConfigIntegrityReport, error) {
	file, err := os.Open(path) // #nosec G304 - operator-supplied configuration path, same one parseEnvFile opens
	if err != nil {
		return nil, fmt.Errorf("cannot open config file: %w", err)
	}
	defer func() { _ = file.Close() }()

	fileScan, err := scanEnvAssignments(bufio.NewScanner(file))
	if err != nil {
		return nil, fmt.Errorf("error reading config file: %w", err)
	}
	templateScan, err := scanEnvAssignments(bufio.NewScanner(strings.NewReader(DefaultEnvTemplate())))
	if err != nil {
		return nil, fmt.Errorf("error reading embedded template: %w", err)
	}

	report := &ConfigIntegrityReport{
		Path:              path,
		Lines:             fileScan.lines,
		Assignments:       fileScan.assignments,
		Distinct:          len(fileScan.order),
		TemplateVariables: len(templateScan.order),
		SkippedMultiValue: skippedMultiValueVariables(),
	}

	for _, name := range fileScan.order {
		at := fileScan.assignedAt[name]
		if len(at) > 1 && !skipsUniquenessCheck(name) {
			report.Duplicated = append(report.Duplicated, DuplicatedVariable{
				Name:        name,
				Lines:       at,
				WinningLine: at[len(at)-1],
			})
		}
		if _, ok := templateScan.assignedAt[name]; !ok {
			report.Unknown = append(report.Unknown, name)
		}
	}
	for _, name := range templateScan.order {
		if _, ok := fileScan.assignedAt[name]; !ok {
			report.Absent = append(report.Absent, name)
		}
	}
	return report, nil
}

// envScan is one pass over an env file: which variables are assigned, on which
// lines, and how many lines and assignments the file has.
type envScan struct {
	order       []string
	assignedAt  map[string][]int
	lines       int
	assignments int
}

// scanEnvAssignments mirrors parseEnvFile's loop exactly, including the multi-line
// block form, so a line the loader ignores is a line the audit ignores.
func scanEnvAssignments(scanner *bufio.Scanner) (envScan, error) {
	scan := envScan{assignedAt: make(map[string][]int)}
	for scanner.Scan() {
		scan.lines++
		line := strings.TrimRight(scanner.Text(), "\r")
		trimmed := strings.TrimSpace(line)
		if utils.IsComment(trimmed) {
			continue
		}
		key, _, ok := utils.SplitKeyValue(line)
		if !ok {
			continue
		}
		if fields := strings.Fields(key); len(fields) >= 2 && fields[0] == "export" {
			key = fields[1]
		}
		upperKey := strings.ToUpper(key)
		if _, seen := scan.assignedAt[upperKey]; !seen {
			scan.order = append(scan.order, upperKey)
		}
		scan.assignedAt[upperKey] = append(scan.assignedAt[upperKey], scan.lines)
		scan.assignments++

		// A block value swallows its own lines in the loader, so the audit has to
		// swallow them too or it would read a value line as an assignment.
		if blockValueKeys[upperKey] && trimmed == fmt.Sprintf("%s=\"", key) {
			for scanner.Scan() {
				scan.lines++
				next := strings.TrimRight(scanner.Text(), "\r")
				if strings.TrimSpace(next) == "\"" {
					break
				}
			}
		}
	}
	if err := scanner.Err(); err != nil {
		return envScan{}, err
	}
	return scan, nil
}

// skipsUniquenessCheck reports whether repeating a variable is by design. The
// multi-value and block forms concatenate in parseEnvFile instead of overwriting,
// so a second line adds to the value and discards nothing.
func skipsUniquenessCheck(upperKey string) bool {
	return multiValueKeys[upperKey] || blockValueKeys[upperKey]
}

func skippedMultiValueVariables() []string {
	set := make(map[string]struct{}, len(multiValueKeys)+len(blockValueKeys))
	for key := range multiValueKeys {
		set[key] = struct{}{}
	}
	for key := range blockValueKeys {
		set[key] = struct{}{}
	}
	names := make([]string, 0, len(set))
	for key := range set {
		names = append(names, key)
	}
	sort.Strings(names)
	return names
}
