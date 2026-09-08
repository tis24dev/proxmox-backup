package orchestrator

import (
	"errors"
	"os"
	"testing"
)

const stagedAcmeAccountsDir = "/stage/etc/proxmox-backup/acme/accounts"

func withFakeRestoreFS(t *testing.T) *FakeFS {
	t.Helper()
	orig := restoreFS
	fakeFS := NewFakeFS()
	restoreFS = fakeFS
	t.Cleanup(func() {
		restoreFS = orig
		_ = os.RemoveAll(fakeFS.Root)
	})
	return fakeFS
}

// The staged apply mirrors the backup: accounts the backup carries are written, accounts
// only the system has are removed. Anything less would leave the node holding a
// registration the restored node.cfg does not reference.
func TestApplyPBSAcmeAccountsFromStage_MirrorsStagedDirectory(t *testing.T) {
	fakeFS := withFakeRestoreFS(t)

	if err := fakeFS.WriteFile(stagedAcmeAccountsDir+"/le", []byte(`{"account":{"status":"valid"}}`), 0o600); err != nil {
		t.Fatalf("write staged account: %v", err)
	}
	if err := fakeFS.WriteFile("/etc/proxmox-backup/acme/accounts/le", []byte(`{"account":{"status":"stale"}}`), 0o600); err != nil {
		t.Fatalf("write live account: %v", err)
	}
	if err := fakeFS.WriteFile("/etc/proxmox-backup/acme/accounts/le-staging", []byte(`{"account":{}}`), 0o600); err != nil {
		t.Fatalf("write live extra account: %v", err)
	}

	if err := applyPBSAcmeAccountsFromStage(newTestLogger(), "/stage"); err != nil {
		t.Fatalf("applyPBSAcmeAccountsFromStage: %v", err)
	}

	data, err := fakeFS.ReadFile("/etc/proxmox-backup/acme/accounts/le")
	if err != nil {
		t.Fatalf("read applied account: %v", err)
	}
	if string(data) != `{"account":{"status":"valid"}}` {
		t.Fatalf("account not replaced by the staged copy: %s", data)
	}
	if _, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts/le-staging"); err == nil {
		t.Fatal("expected an account absent from the backup to be removed")
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stat removed account: %v", err)
	}

	info, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts")
	if err != nil {
		t.Fatalf("stat accounts dir: %v", err)
	}
	if perm := info.Mode().Perm(); perm != 0o700 {
		t.Fatalf("expected the account directory at 0700 (PBS default), got %o", perm)
	}
	if fileInfo, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts/le"); err != nil {
		t.Fatalf("stat applied account: %v", err)
	} else if perm := fileInfo.Mode().Perm(); perm != 0o600 {
		t.Fatalf("expected the account file at 0600, got %o", perm)
	}
}

// An archive that carries no accounts directory says nothing about accounts (it predates
// the fix, or the toggle was off at backup time), so the live registrations must survive.
func TestApplyPBSAcmeAccountsFromStage_AbsentStageLeavesSystemUntouched(t *testing.T) {
	fakeFS := withFakeRestoreFS(t)

	if err := fakeFS.WriteFile("/etc/proxmox-backup/acme/accounts/le", []byte(`{"account":{}}`), 0o600); err != nil {
		t.Fatalf("write live account: %v", err)
	}

	if err := applyPBSAcmeAccountsFromStage(newTestLogger(), "/stage"); err != nil {
		t.Fatalf("applyPBSAcmeAccountsFromStage: %v", err)
	}

	if _, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts/le"); err != nil {
		t.Fatalf("expected the live account untouched when the stage has no accounts directory: %v", err)
	}
}

// A staged directory that exists and is empty is a backup taken with zero accounts, which
// under mirror semantics means the system must end with zero accounts.
func TestApplyPBSAcmeAccountsFromStage_EmptyStagedDirectoryRemovesAll(t *testing.T) {
	fakeFS := withFakeRestoreFS(t)

	if err := fakeFS.MkdirAll(stagedAcmeAccountsDir, 0o700); err != nil {
		t.Fatalf("mkdir staged accounts: %v", err)
	}
	if err := fakeFS.WriteFile("/etc/proxmox-backup/acme/accounts/le", []byte(`{"account":{}}`), 0o600); err != nil {
		t.Fatalf("write live account: %v", err)
	}

	if err := applyPBSAcmeAccountsFromStage(newTestLogger(), "/stage"); err != nil {
		t.Fatalf("applyPBSAcmeAccountsFromStage: %v", err)
	}

	entries, err := fakeFS.ReadDir("/etc/proxmox-backup/acme/accounts")
	if err != nil {
		t.Fatalf("read accounts dir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected every account removed, got %d entries", len(entries))
	}
}

func TestApplyPBSAcmeAccountsFromStage_SkipsNonRegularStagedEntries(t *testing.T) {
	fakeFS := withFakeRestoreFS(t)

	if err := fakeFS.WriteFile(stagedAcmeAccountsDir+"/le", []byte(`{"account":{}}`), 0o600); err != nil {
		t.Fatalf("write staged account: %v", err)
	}
	if err := fakeFS.MkdirAll(stagedAcmeAccountsDir+"/nested", 0o700); err != nil {
		t.Fatalf("mkdir staged nested: %v", err)
	}

	if err := applyPBSAcmeAccountsFromStage(newTestLogger(), "/stage"); err != nil {
		t.Fatalf("applyPBSAcmeAccountsFromStage: %v", err)
	}

	if _, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts/le"); err != nil {
		t.Fatalf("expected the regular staged account applied: %v", err)
	}
	if _, err := fakeFS.Stat("/etc/proxmox-backup/acme/accounts/nested"); err == nil {
		t.Fatal("expected a non-regular staged entry not to be carried onto the system")
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stat nested: %v", err)
	}
}

// The staged path is a directory on every PBS release; a stage holding a file there is a
// corrupt or hand-made archive and must surface as an error rather than be applied.
func TestApplyPBSAcmeAccountsFromStage_RejectsFileWhereDirectoryExpected(t *testing.T) {
	fakeFS := withFakeRestoreFS(t)

	if err := fakeFS.WriteFile(stagedAcmeAccountsDir, []byte("account: a1\n"), 0o600); err != nil {
		t.Fatalf("write staged file: %v", err)
	}

	err := applyPBSAcmeAccountsFromStage(newTestLogger(), "/stage")
	if err == nil {
		t.Fatal("expected an error when the staged accounts path is not a directory")
	}
}
