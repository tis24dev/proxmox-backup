package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/tis24dev/proxmox-backup/internal/config"
)

type configStatusLogger interface {
	Warning(format string, args ...interface{})
	Info(format string, args ...interface{})
}

func resolveInstallConfigPath(configPath string) (string, error) {
	configPath = strings.TrimSpace(configPath)
	if configPath == "" {
		return "", fmt.Errorf("configuration path is empty")
	}

	if filepath.IsAbs(configPath) {
		return configPath, nil
	}

	baseDir, ok := detectBaseDir()
	if !ok {
		return "", fmt.Errorf("unable to determine base directory for configuration")
	}
	return filepath.Join(baseDir, configPath), nil
}

func ensureConfigExists(path string, logger configStatusLogger) error {
	if strings.TrimSpace(path) == "" {
		return fmt.Errorf("configuration path is empty")
	}

	if _, err := os.Stat(path); err == nil {
		return nil
	} else if !os.IsNotExist(err) {
		return fmt.Errorf("failed to stat configuration file: %w", err)
	}

	// Attempt automatic migration from legacy Bash env (env/backup.env) if present.
	if migrated, err := migrateLegacyEnvIfPresent(path, logger); err != nil {
		logger.Warning("WARNING: Failed to migrate legacy env file: %v", err)
	} else if migrated {
		return nil
	}

	logger.Warning("Configuration file not found: %s", path)
	fmt.Print("Generate default configuration from template? [y/N]: ")

	reader := bufio.NewReader(os.Stdin)
	response, err := reader.ReadString('\n')
	if err != nil && err != io.EOF {
		return fmt.Errorf("failed to read user input: %w", err)
	}

	answer := strings.ToLower(strings.TrimSpace(response))
	if answer != "y" && answer != "yes" {
		return fmt.Errorf("configuration file is required to continue")
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("failed to create configuration directory %s: %w", dir, err)
	}

	if err := os.WriteFile(path, []byte(config.DefaultEnvTemplate()), 0o600); err != nil {
		return fmt.Errorf("failed to write default configuration: %w", err)
	}

	logger.Info("✓ Default configuration created at %s", path)
	return nil
}

// migrateLegacyEnvIfPresent checks for a legacy Bash env file (env/backup.env)
// under likely base directories and, if found, generates a new Go-style
// configs/backup.env by overlaying legacy key=values onto the default template.
func migrateLegacyEnvIfPresent(newConfigPath string, logger configStatusLogger) (bool, error) {
	newConfigPath = strings.TrimSpace(newConfigPath)
	if newConfigPath == "" {
		return false, fmt.Errorf("empty config path for migration")
	}

	// Candidate base directories: derived from config path, from executable info, and the legacy default.
	var baseDirs []string
	if dir := filepath.Dir(filepath.Dir(newConfigPath)); dir != "" && dir != "." && dir != string(filepath.Separator) {
		baseDirs = append(baseDirs, dir)
	}
	if info := getExecInfo(); info.BaseDir != "" {
		baseDirs = append(baseDirs, info.BaseDir)
	}
	baseDirs = append(baseDirs, "/opt/proxmox-backup")

	seen := make(map[string]struct{})
	var legacyEnvPath string
	for _, dir := range baseDirs {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			continue
		}
		if _, ok := seen[dir]; ok {
			continue
		}
		seen[dir] = struct{}{}
		candidate := filepath.Join(dir, "env", "backup.env")
		info, err := os.Stat(candidate)
		if err != nil {
			if !os.IsNotExist(err) {
				logger.Warning("WARNING: Failed to stat legacy env candidate %s: %v", candidate, err)
			}
			continue
		}
		if info.IsDir() {
			continue
		}
		legacyEnvPath = candidate
		break
	}

	if legacyEnvPath == "" {
		return false, nil
	}

	logger.Info("Detected legacy env configuration at %s; migrating to %s", legacyEnvPath, newConfigPath)

	data, err := os.ReadFile(legacyEnvPath)
	if err != nil {
		return false, fmt.Errorf("failed to read legacy env file %s: %w", legacyEnvPath, err)
	}

	legacyKV := parseKeyValues(string(data))
	template := config.DefaultEnvTemplate()

	// Overlay all legacy keys onto the template; Go parser will ignore unknown keys.
	for k, v := range legacyKV {
		if strings.TrimSpace(k) == "" {
			continue
		}
		template = setEnvValue(template, k, v)
	}

	// Ensure BASE_DIR is explicitly set and consistent with the new config location.
	baseDir := filepath.Dir(filepath.Dir(newConfigPath))
	if baseDir == "" || baseDir == "." || baseDir == string(filepath.Separator) {
		if info := getExecInfo(); info.BaseDir != "" {
			baseDir = info.BaseDir
		} else {
			baseDir = "/opt/proxmox-backup"
		}
	}
	template = setEnvValue(template, "BASE_DIR", baseDir)

	dir := filepath.Dir(newConfigPath)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return false, fmt.Errorf("failed to create configuration directory %s: %w", dir, err)
	}
	if err := os.WriteFile(newConfigPath, []byte(template), 0o600); err != nil {
		return false, fmt.Errorf("failed to write migrated configuration: %w", err)
	}

	logger.Info("✓ Migrated legacy env to %s", newConfigPath)
	return true, nil
}

// parseKeyValues parses a simple KEY=VALUE env-style file, ignoring comments and
// stripping surrounding quotes and inline comments from the value.
func parseKeyValues(raw string) map[string]string {
	result := make(map[string]string)
	scanner := bufio.NewScanner(strings.NewReader(raw))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// Ignore shebang or non KEY=VALUE lines
		if strings.HasPrefix(line, "#!") {
			continue
		}
		idx := strings.IndexByte(line, '=')
		if idx <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:idx])
		if key == "" {
			continue
		}
		rest := strings.TrimSpace(line[idx+1:])
		// Strip inline comments (unquoted)
		if hash := strings.Index(rest, "#"); hash >= 0 {
			rest = strings.TrimSpace(rest[:hash])
		}
		// Strip surrounding single or double quotes
		if len(rest) >= 2 {
			if (rest[0] == '"' && rest[len(rest)-1] == '"') ||
				(rest[0] == '\'' && rest[len(rest)-1] == '\'') {
				rest = rest[1 : len(rest)-1]
			}
		}
		if rest == "" {
			continue
		}
		result[key] = rest
	}
	return result
}

func setEnvValue(template, key, value string) string {
	target := key + "="
	lines := strings.Split(template, "\n")
	replaced := false
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, target) {
			leadingLen := len(line) - len(strings.TrimLeft(line, " \t"))
			leading := ""
			if leadingLen > 0 {
				leading = line[:leadingLen]
			}
			rest := line[leadingLen:]
			commentSpacing := ""
			comment := ""
			if idx := strings.Index(rest, "#"); idx >= 0 {
				before := rest[:idx]
				comment = rest[idx:]
				trimmedBefore := strings.TrimRight(before, " \t")
				commentSpacing = before[len(trimmedBefore):]
				rest = trimmedBefore
			}
			newLine := leading + key + "=" + value
			if comment != "" {
				spacing := commentSpacing
				if spacing == "" {
					spacing = " "
				}
				newLine += spacing + comment
			}
			lines[i] = newLine
			replaced = true
		}
	}
	if !replaced {
		lines = append(lines, key+"="+value)
	}
	return strings.Join(lines, "\n")
}

func sanitizeEnvValue(value string) string {
	value = strings.Map(func(r rune) rune {
		if r == '\n' || r == '\r' || r == '\x00' {
			return -1
		}
		return r
	}, value)
	return strings.TrimSpace(value)
}
