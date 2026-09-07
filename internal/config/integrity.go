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
// Lines holds every assignment line in file order; WinningLine is the one whose
// value survives. For an ordinary variable that is the last assignment, because
// parseEnvFile writes raw[upperKey] on every hit. For a variable written in the
// block form it is the last BLOCK, which replaces what came before it while a
// later single line only concatenates onto it. See discardsAValue.
// The discarded values are deliberately NOT recorded: a duplicated
// TELEGRAM_BOT_TOKEN would put a secret in the log, and the line number is
// enough for the operator to find it.
type DuplicatedVariable struct {
	Name        string
	Lines       []int
	WinningLine int
	// Discarded holds the lines whose value is thrown away, in file order. It is
	// NOT "every line but the winner": an assignment that follows a block
	// concatenates onto it and loses nothing, so it appears in Lines and not here.
	Discarded []int
}

// VariableAssignment describes HOW one variable is assigned in the audited file:
// every line that assigns it, the one whose value is in effect, and whether that one
// carries an empty value. The value itself is never recorded, so a duplicated
// TELEGRAM_BOT_TOKEN cannot reach a log through here either.
//
// WinningLine is not simply the last line. It is the last assignment that REPLACES,
// which for an ordinary variable is indeed the last one, but for a variable written
// in the block form is the last block: a line after a block concatenates onto it
// rather than winning over it. See replacingAssignment.
type VariableAssignment struct {
	Lines        []int
	WinningLine  int
	WinningEmpty bool
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

	// assignments answers "how is this variable written in the file" for callers that
	// need to explain ONE variable rather than list the file's findings, e.g. the
	// daemon diagnostics saying why a personal script reads as NOT CONFIGURED.
	assignments map[string]VariableAssignment
}

// Assignment reports how a variable is assigned in the audited file. The second
// return is false when the variable is not assigned at all, which is a different
// fact from being assigned with an empty value and has to stay distinguishable.
func (r *ConfigIntegrityReport) Assignment(name string) (VariableAssignment, bool) {
	if r == nil || r.assignments == nil {
		return VariableAssignment{}, false
	}
	assignment, ok := r.assignments[strings.ToUpper(strings.TrimSpace(name))]
	return assignment, ok
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
		assignments:       make(map[string]VariableAssignment, len(fileScan.order)),
	}

	for _, name := range fileScan.order {
		at := fileScan.assignedAt[name]
		lines := make([]int, 0, len(at))
		for _, entry := range at {
			lines = append(lines, entry.line)
		}
		inEffect := at[replacingAssignment(name, at)]
		report.assignments[name] = VariableAssignment{
			Lines:        lines,
			WinningLine:  inEffect.line,
			WinningEmpty: inEffect.empty,
		}
		if winning, discarded := discardsAValue(name, at); len(discarded) > 0 {
			report.Duplicated = append(report.Duplicated, DuplicatedVariable{
				Name:        name,
				Lines:       lines,
				WinningLine: winning,
				Discarded:   discarded,
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

// envAssignment is one KEY=VALUE line: where it is, and whether its value is empty.
// The value is deliberately not kept.
type envAssignment struct {
	line  int
	empty bool
	block bool
}

// envScan is one pass over an env file: which variables are assigned, on which
// lines, and how many lines and assignments the file has.
type envScan struct {
	order       []string
	assignedAt  map[string][]envAssignment
	lines       int
	assignments int
}

// scanEnvAssignments mirrors parseEnvFile's loop exactly, including the multi-line
// block form, so a line the loader ignores is a line the audit ignores.
func scanEnvAssignments(scanner *bufio.Scanner) (envScan, error) {
	scan := envScan{assignedAt: make(map[string][]envAssignment)}
	for scanner.Scan() {
		scan.lines++
		line := strings.TrimRight(scanner.Text(), "\r")
		trimmed := strings.TrimSpace(line)
		if utils.IsComment(trimmed) {
			continue
		}
		key, value, ok := utils.SplitKeyValue(line)
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
		// A block value swallows its own lines in the loader, so the audit has to
		// swallow them too or it would read a value line as an assignment. Which
		// form this is also decides whether repeating the variable discards
		// anything, so the answer is kept on the assignment.
		opensBlock := blockValueKeys[upperKey] && trimmed == fmt.Sprintf("%s=\"", key)
		scan.assignedAt[upperKey] = append(scan.assignedAt[upperKey], envAssignment{
			line:  scan.lines,
			empty: strings.TrimSpace(value) == "",
			block: opensBlock,
		})
		scan.assignments++

		if opensBlock {
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

// discardsAValue reports whether repeating a variable throws away something the
// file already set, and which assignment does the throwing away.
//
// The loader does not resolve every variable by last-wins, so the audit cannot
// either:
//
//   - an ordinary variable is overwritten by every later assignment;
//   - the single-line form of a multi-value variable CONCATENATES, ending its
//     branch with `raw[upperKey] = existing + "\n" + value`, so it discards
//     nothing however often it is repeated;
//   - the block form does NOT concatenate. Its branch ends with a plain
//     `raw[upperKey] = strings.Join(blockLines, "\n")`, so a block replaces
//     everything the file set before it, an earlier block included. Assignments
//     that follow the last block concatenate onto it and lose nothing.
//
// The third case is why exempting the block variables outright was wrong: the
// shipped template writes both of them in block form, so an operator who adds
// their own line above one loses it in silence.
func discardsAValue(upperKey string, at []envAssignment) (winning int, discarded []int) {
	if len(at) < 2 {
		return 0, nil
	}
	replacing := replacingAssignment(upperKey, at)
	if replacing == 0 {
		return 0, nil
	}
	for _, assignment := range at[:replacing] {
		discarded = append(discarded, assignment.line)
	}
	return at[replacing].line, discarded
}

// replacingAssignment returns the index of the assignment whose value is in effect
// as the base: the LAST one that replaces rather than concatenates. Everything
// before it is thrown away; everything after it adds to it.
func replacingAssignment(upperKey string, at []envAssignment) int {
	if blockValueKeys[upperKey] {
		last := -1
		for i := range at {
			if at[i].block {
				last = i
			}
		}
		if last < 0 {
			// No block in the file: every assignment is the single-line form, which
			// concatenates, so the first one sets the value and the rest add to it.
			return 0
		}
		return last
	}
	if multiValueKeys[upperKey] {
		return 0
	}
	return len(at) - 1
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
