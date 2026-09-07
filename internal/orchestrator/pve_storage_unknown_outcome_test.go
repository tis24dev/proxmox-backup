package orchestrator

import (
	"context"
	"os"
	"strings"
	"testing"
)

// storageOutcomeFixture stages one storage block against a node that already has
// that definition, so applyStorageCfg takes the create-fails/set-fallback path.
func storageOutcomeFixture(t *testing.T, id, cfg string, refuse []string) *schemaAwarePvesh {
	t.Helper()
	origFS, origCmd := restoreFS, restoreCmd
	t.Cleanup(func() { restoreFS, restoreCmd = origFS, origCmd })
	fakeFS := NewFakeFS()
	t.Cleanup(func() { _ = os.RemoveAll(fakeFS.Root) })
	restoreFS = fakeFS
	pvesh := newSchemaAwarePvesh(id)
	for _, key := range refuse {
		pvesh.refuseStorageSetKeys[key] = true
	}
	restoreCmd = pvesh
	if err := fakeFS.AddFile("/stage/etc/pve/storage.cfg", []byte(cfg)); err != nil {
		t.Fatal(err)
	}
	return pvesh
}

// Nothing reached the node, every staged key was refused, and the live definition
// could not be read. The restore does not know whether those values are in effect:
// a create-only key may already hold the staged value, or it may not. Counting that
// as applied hands the caller ok=1 failed=0, and the staged-apply arm returns nil,
// so a restore whose storage state is unknown reports success.
func TestAnUnreadableLiveDefinitionIsNotAnApply(t *testing.T) {
	pvesh := storageOutcomeFixture(t, "onlypath", "dir: onlypath\n\tpath /var/lib/vz\n", nil)
	pvesh.storageGetError["onlypath"] = errString("500 no such storage")
	logger, buf := nothingSettableLogger(t)

	applied, unknown, failed, err := applyStorageCfg(context.Background(), "/stage/etc/pve/storage.cfg", logger)
	if err != nil {
		t.Fatalf("applyStorageCfg: %v", err)
	}
	if failed != 0 {
		t.Fatalf("failed=%d: nothing was established as wrong, so this is not a failure either", failed)
	}
	if applied != 0 || unknown != 1 {
		t.Fatalf("applied=%d unknown=%d, want 0/1: the live definition could not be read, so nothing is known to have been applied", applied, unknown)
	}
	out := buf.String()
	if !strings.Contains(out, "not comparable") || !strings.Contains(out, "path") {
		t.Fatalf("the warning must name the keys it could not judge; got:\n%s", out)
	}
}

// Two refused keys, only one of them present in the live definition. The comparison
// covered half the question and the other half is unanswered, so announcing that the
// definition "already matches every staged key the update schema refuses" claims a
// check that was never made on the missing key.
func TestAPartlyComparedDefinitionIsNotAMatch(t *testing.T) {
	pvesh := storageOutcomeFixture(t, "nas",
		"nfs: nas\n\tserver 10.0.0.1\n\texport /srv/backups\n",
		[]string{"server", "export"})
	pvesh.storageLive["nas"] = map[string]any{"server": "10.0.0.1"}
	logger, buf := nothingSettableLogger(t)

	applied, unknown, failed, err := applyStorageCfg(context.Background(), "/stage/etc/pve/storage.cfg", logger)
	if err != nil {
		t.Fatalf("applyStorageCfg: %v", err)
	}
	if failed != 0 {
		t.Fatalf("failed=%d: the compared key matched, so nothing is known to be wrong", failed)
	}
	if applied != 0 || unknown != 1 {
		t.Fatalf("applied=%d unknown=%d, want 0/1: export was never compared against anything", applied, unknown)
	}
	out := buf.String()
	if strings.Contains(out, "already matches every staged key") {
		t.Fatalf("a half-made comparison was announced as complete:\n%s", out)
	}
	if !strings.Contains(out, "export") {
		t.Fatalf("the warning must name export, the key it could not judge; got:\n%s", out)
	}
}

// The guard on the other side: when every refused key IS comparable and every one of
// them already holds the staged value, the restore really did establish that the
// definition matches, and that is an apply.
func TestAFullyComparedMatchIsStillAnApply(t *testing.T) {
	pvesh := storageOutcomeFixture(t, "nas",
		"nfs: nas\n\tserver 10.0.0.1\n\texport /srv/backups\n",
		[]string{"server", "export"})
	pvesh.storageLive["nas"] = map[string]any{"server": "10.0.0.1", "export": "/srv/backups"}
	logger, buf := nothingSettableLogger(t)

	applied, unknown, failed, err := applyStorageCfg(context.Background(), "/stage/etc/pve/storage.cfg", logger)
	if err != nil {
		t.Fatalf("applyStorageCfg: %v", err)
	}
	if applied != 1 || unknown != 0 || failed != 0 {
		t.Fatalf("applied=%d unknown=%d failed=%d, want 1/0/0: every refused key was compared and every one matched", applied, unknown, failed)
	}
	if out := buf.String(); !strings.Contains(out, "already matches every staged key") {
		t.Fatalf("missing the match line in:\n%s", out)
	}
}

// And the failure side stays a failure: a refused key whose live value differs is a
// staged value the restore could not put back, and that IS established.
func TestARefusedKeyThatDiffersIsStillAFailure(t *testing.T) {
	pvesh := storageOutcomeFixture(t, "nas",
		"nfs: nas\n\tserver 10.0.0.1\n\texport /srv/backups\n",
		[]string{"server", "export"})
	pvesh.storageLive["nas"] = map[string]any{"server": "10.0.0.1", "export": "/srv/OLD"}
	logger, buf := nothingSettableLogger(t)

	applied, unknown, failed, err := applyStorageCfg(context.Background(), "/stage/etc/pve/storage.cfg", logger)
	if err != nil {
		t.Fatalf("applyStorageCfg: %v", err)
	}
	if applied != 0 || unknown != 0 || failed != 1 {
		t.Fatalf("applied=%d unknown=%d failed=%d, want 0/0/1: export differs from the staged value", applied, unknown, failed)
	}
	if out := buf.String(); !strings.Contains(out, "does not match the staged value") || !strings.Contains(out, "export") {
		t.Fatalf("the warning must name export as the differing key; got:\n%s", out)
	}
}
