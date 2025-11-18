package config

import _ "embed"

// defaultEnvTemplate holds the embedded Go configuration template.
//
//go:embed templates/backup.env
var defaultEnvTemplate string

// DefaultEnvTemplate returns the embedded configuration template used to
// bootstrap new installations.
func DefaultEnvTemplate() string {
	return defaultEnvTemplate
}
