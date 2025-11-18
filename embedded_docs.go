package proxmoxbackup

import _ "embed"

var (
	//go:embed README.md
	embeddedReadme []byte

	//go:embed BACKUP_ENV_MAPPING.md
	embeddedBackupEnvMapping []byte
)

// DocAsset represents an embedded documentation file that can be
// materialized during installation.
type DocAsset struct {
	Name string
	Data []byte
}

// InstallableDocs returns the list of documentation files embedded in the
// binary that should be written to the installation root.
func InstallableDocs() []DocAsset {
	return []DocAsset{
		{Name: "README.md", Data: embeddedReadme},
		{Name: "BACKUP_ENV_MAPPING.md", Data: embeddedBackupEnvMapping},
	}
}
