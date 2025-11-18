package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const upgradeTemplate = `BACKUP_PATH=/default/backup
LOG_PATH=/default/log
KEY1=template
`

func TestPlanUpgradeConfigNoChanges(t *testing.T) {
	withTemplate(t, upgradeTemplate, func() {
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, "backup.env")
		if err := os.WriteFile(configPath, []byte(upgradeTemplate), 0600); err != nil {
			t.Fatalf("failed to seed config: %v", err)
		}

		result, err := PlanUpgradeConfigFile(configPath)
		if err != nil {
			t.Fatalf("PlanUpgradeConfigFile returned error: %v", err)
		}
		if result.Changed {
			t.Fatalf("result.Changed = true; want false for identical config")
		}
	})
}

func TestUpgradeConfigAddsMissingKeys(t *testing.T) {
	withTemplate(t, upgradeTemplate, func() {
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, "backup.env")
		legacy := "BACKUP_PATH=/legacy\n"
		if err := os.WriteFile(configPath, []byte(legacy), 0600); err != nil {
			t.Fatalf("failed to write legacy config: %v", err)
		}

		result, err := UpgradeConfigFile(configPath)
		if err != nil {
			t.Fatalf("UpgradeConfigFile returned error: %v", err)
		}
		if !result.Changed {
			t.Fatalf("expected result.Changed=true for missing keys")
		}
		data, err := os.ReadFile(configPath)
		if err != nil {
			t.Fatalf("failed to read upgraded config: %v", err)
		}
		content := string(data)
		if !strings.Contains(content, "BACKUP_PATH=/legacy") {
			t.Fatalf("upgraded config does not keep legacy BACKUP_PATH: %s", content)
		}
		if !strings.Contains(content, "LOG_PATH=/default/log") {
			t.Fatalf("upgraded config missing template key LOG_PATH")
		}
	})
}

func TestPlanUpgradeTracksExtraKeys(t *testing.T) {
	withTemplate(t, upgradeTemplate, func() {
		tmpDir := t.TempDir()
		configPath := filepath.Join(tmpDir, "backup.env")
		content := "BACKUP_PATH=/legacy\nEXTRA_KEY=value\n"
		if err := os.WriteFile(configPath, []byte(content), 0600); err != nil {
			t.Fatalf("failed to write config: %v", err)
		}

		result, err := PlanUpgradeConfigFile(configPath)
		if err != nil {
			t.Fatalf("PlanUpgradeConfigFile returned error: %v", err)
		}
		if len(result.ExtraKeys) != 1 || result.ExtraKeys[0] != "EXTRA_KEY" {
			t.Fatalf("ExtraKeys = %v; want [EXTRA_KEY]", result.ExtraKeys)
		}
	})
}
