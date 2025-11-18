package config

import "testing"

func withTemplate(t *testing.T, template string, fn func()) {
	t.Helper()
	orig := defaultEnvTemplate
	defaultEnvTemplate = template
	defer func() { defaultEnvTemplate = orig }()
	fn()
}
