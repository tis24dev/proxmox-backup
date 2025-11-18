package orchestrator

import "testing"

func TestValidatePassphraseStrength(t *testing.T) {
	tests := []struct {
		name    string
		pass    string
		wantErr bool
	}{
		{"strong", "Str0ng!Passphrase", false},
		{"too short", "Short1!", true},
		{"missing classes", "alllowercasepassword", true},
		{"common password", "Password", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validatePassphraseStrength([]byte(tt.pass))
			if tt.wantErr && err == nil {
				t.Fatalf("expected error for %q", tt.pass)
			}
			if !tt.wantErr && err != nil {
				t.Fatalf("unexpected error for %q: %v", tt.pass, err)
			}
		})
	}
}
