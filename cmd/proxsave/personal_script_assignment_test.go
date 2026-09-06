package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/tis24dev/proxsave/internal/config"
	"github.com/tis24dev/proxsave/internal/logging"
	"github.com/tis24dev/proxsave/internal/types"
)

func auditFixture(t *testing.T, body string) *config.ConfigIntegrityReport {
	t.Helper()
	path := filepath.Join(t.TempDir(), "backup.env")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	report, err := config.AuditConfigFile(path)
	if err != nil {
		t.Fatalf("audit: %v", err)
	}
	return report
}

func annotatedCurrentSide(t *testing.T, body string) personalScriptsDiagnostics {
	t.Helper()
	report := auditFixture(t, body)
	scripts := personalScriptsDiagnostics{
		Pre:  personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured},
		Post: personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_POST_RUN", State: personalScriptNotConfigured},
	}
	annotatePersonalScriptAssignment(&scripts.Pre, report)
	annotatePersonalScriptAssignment(&scripts.Post, report)
	return scripts
}

// NOT CONFIGURED alone cannot tell three different files apart, and the difference is
// exactly what issue #306 turned on: a variable missing from the file, one assigned
// empty, and one whose value a later line overwrites.
func TestNotConfiguredSaysWhatTheFileActuallyContains(t *testing.T) {
	cases := map[string]struct {
		body string
		want string
	}{
		"not assigned at all": {
			"EMAIL_ENABLED=true\n",
			"PERSONAL_SCRIPT_PRE_RUN is not in the file",
		},
		"assigned once with an empty value": {
			"EMAIL_ENABLED=true\nPERSONAL_SCRIPT_PRE_RUN=\n",
			"PERSONAL_SCRIPT_PRE_RUN is on line 2 & is empty",
		},
		"operator line overwritten by a later empty one": {
			"PERSONAL_SCRIPT_PRE_RUN=/home/howard/dd/mount-pbs\nEMAIL_ENABLED=true\nPERSONAL_SCRIPT_PRE_RUN=\n",
			"PERSONAL_SCRIPT_PRE_RUN is on lines 1 and 3 & line 3 wins and is empty",
		},
		"three assignments read as a sentence": {
			"PERSONAL_SCRIPT_PRE_RUN=/a\nPERSONAL_SCRIPT_PRE_RUN=/b\nPERSONAL_SCRIPT_PRE_RUN=\n",
			"PERSONAL_SCRIPT_PRE_RUN is on lines 1, 2 and 3 & line 3 wins and is empty",
		},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			if got := annotatedCurrentSide(t, tc.body).Pre.Assignment; got != tc.want {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}
}

// Both operator scripts are explained, not just the pre-run one.
func TestBothPersonalScriptsGetTheirOwnExplanation(t *testing.T) {
	scripts := annotatedCurrentSide(t, "PERSONAL_SCRIPT_POST_RUN=\n")
	if scripts.Pre.Assignment != "PERSONAL_SCRIPT_PRE_RUN is not in the file" {
		t.Fatalf("pre-run: %q", scripts.Pre.Assignment)
	}
	if scripts.Post.Assignment != "PERSONAL_SCRIPT_POST_RUN is on line 1 & is empty" {
		t.Fatalf("post-run: %q", scripts.Post.Assignment)
	}
}

// The note describes the file as it is RIGHT NOW, so it cannot be attached to a verdict
// the daemon reached from its own copy when it started.
func TestOnlyTheCurrentSideIsAnnotated(t *testing.T) {
	report := auditFixture(t, "PERSONAL_SCRIPT_PRE_RUN=\n")
	current := personalScriptsDiagnostics{
		Pre:  personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured},
		Post: personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_POST_RUN", State: personalScriptNotConfigured},
	}
	annotatePersonalScriptAssignments(&current, report.Path)
	if current.Pre.Assignment == "" {
		t.Fatalf("the current side must be annotated")
	}

	running := personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured}
	comparison := comparePersonalScript(
		daemonRuntimeDiagnostic{Availability: daemonRuntimeAvailable, ConfigPath: report.Path},
		report.Path, running, current.Pre,
	)
	if comparison.Running.Assignment != "" {
		t.Fatalf("the running side must carry no file note, got %q", comparison.Running.Assignment)
	}
}

// The regression this design exists to avoid: comparePersonalScript compares Reason
// between the two sides, so putting the note there would make every explained
// NOT CONFIGURED report PATH STATE CHANGED, a warning about a daemon that is fine.
func TestExplainingTheVerdictDoesNotBreakSynchronization(t *testing.T) {
	report := auditFixture(t, "PERSONAL_SCRIPT_PRE_RUN=\n")
	current := personalScriptsDiagnostics{
		Pre:  personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured},
		Post: personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_POST_RUN", State: personalScriptNotConfigured},
	}
	annotatePersonalScriptAssignments(&current, report.Path)

	comparison := comparePersonalScript(
		daemonRuntimeDiagnostic{Availability: daemonRuntimeAvailable, ConfigPath: report.Path},
		report.Path,
		personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured},
		current.Pre,
	)
	if comparison.Synchronization != personalScriptInSync {
		t.Fatalf("two sides that agree must stay IN SYNC, got %q (%s)",
			comparison.Synchronization, comparison.SyncReason)
	}
}

// A configured script needs no explanation, and a verdict the file contradicts gets
// none either rather than arguing with itself.
func TestOnlyANotConfiguredVerdictIsExplained(t *testing.T) {
	report := auditFixture(t, "PERSONAL_SCRIPT_PRE_RUN=/opt/ops/pre.sh\n")
	ready := personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptReady, Path: "/opt/ops/pre.sh"}
	annotatePersonalScriptAssignment(&ready, report)
	if ready.Assignment != "" {
		t.Fatalf("a READY verdict must carry no note, got %q", ready.Assignment)
	}
	contradicted := personalScriptDiagnostic{Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptNotConfigured}
	annotatePersonalScriptAssignment(&contradicted, report)
	if contradicted.Assignment != "" {
		t.Fatalf("a non-empty assignment must not be described as the reason for NOT CONFIGURED, got %q", contradicted.Assignment)
	}

	// The state guard, exercised where it actually bites: an empty variable whose
	// verdict is NOT not-configured. Explaining a REFUSED verdict with "the variable is
	// empty" would contradict the refusal it sits next to.
	emptyInFile := auditFixture(t, "PERSONAL_SCRIPT_PRE_RUN=\n")
	refused := personalScriptDiagnostic{
		Key: "PERSONAL_SCRIPT_PRE_RUN", State: personalScriptRefused,
		Path: "/opt/ops/pre.sh", Reason: "path is not owned by root",
	}
	annotatePersonalScriptAssignment(&refused, emptyInFile)
	if refused.Assignment != "" {
		t.Fatalf("only a NOT CONFIGURED verdict may carry the file note, got %q", refused.Assignment)
	}
}

// The note describes the file read NOW, so the collector must hand it the current side
// and nothing else. No unit test of the annotator can see which side it was given.
func TestTheCollectorAnnotatesTheCurrentSideOnly(t *testing.T) {
	source, err := os.ReadFile("daemon_diagnostics.go")
	if err != nil {
		t.Fatalf("read daemon_diagnostics.go: %v", err)
	}
	body := string(source)
	if got := strings.Count(body, "annotatePersonalScriptAssignments("); got != 1 {
		t.Fatalf("expected exactly one annotation call, got %d", got)
	}
	if !strings.Contains(body, "annotatePersonalScriptAssignments(&currentScripts, currentConfigPath)") {
		t.Fatalf("the annotation must be applied to the current side only")
	}
	if strings.Contains(body, "annotatePersonalScriptAssignments(&runningScripts") {
		t.Fatalf("the running side must never be annotated from today's file")
	}
}

// The note has to reach the operator through both renderers, or only half the surfaces
// answer the question the verdict raises.
func TestBothRenderersShowTheExplanation(t *testing.T) {
	diagnostic := personalScriptDiagnostic{
		Key:        "PERSONAL_SCRIPT_PRE_RUN",
		State:      personalScriptNotConfigured,
		Assignment: "PERSONAL_SCRIPT_PRE_RUN is on lines 120 and 456 & line 456 wins and is empty",
	}
	want := "NOT CONFIGURED (PERSONAL_SCRIPT_PRE_RUN is on lines 120 and 456 & line 456 wins and is empty)"

	if got := stripStyling(buildDashboardPersonalScriptLine("  Configuration", diagnostic)); !strings.Contains(got, want) {
		t.Fatalf("dashboard line missing the explanation: %q", got)
	}
	if got := captureDaemonDiagnosticLine(t, diagnostic); !strings.Contains(got, want) {
		t.Fatalf("CLI line missing the explanation: %q", got)
	}
}

func captureDaemonDiagnosticLine(t *testing.T, diagnostic personalScriptDiagnostic) string {
	t.Helper()
	buf := &bytes.Buffer{}
	logger := logging.New(types.LogLevelDebug, false)
	logger.SetOutput(buf)
	logPersonalScriptDiagnostic(logger, "  Configuration", diagnostic)
	return buf.String()
}

// stripStyling removes the terminal colour codes the dashboard renderer emits, so the
// assertion reads the sentence the operator reads rather than the escape sequences
// interleaved with it.
func stripStyling(line string) string {
	return ansiEscape.ReplaceAllString(line, "")
}

var ansiEscape = regexp.MustCompile(`\x1b\[[0-9;:]*m`)
