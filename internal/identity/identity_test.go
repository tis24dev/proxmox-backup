package identity

import (
	"strings"
	"testing"
)

func TestEncodeDecodeProtectedServerIDRoundTrip(t *testing.T) {
	const serverID = "1234567890123456"
	const mac = "aa:bb:cc:dd:ee:ff"

	content, err := encodeProtectedServerID(serverID, mac)
	if err != nil {
		t.Fatalf("encodeProtectedServerID() error = %v", err)
	}

	decoded, err := decodeProtectedServerID(content, mac)
	if err != nil {
		t.Fatalf("decodeProtectedServerID() error = %v\ncontent:\n%s", err, content)
	}
	if decoded != serverID {
		t.Fatalf("decoded server ID = %s, want %s", decoded, serverID)
	}
}

func TestDecodeProtectedServerIDRejectsDifferentHost(t *testing.T) {
	const serverID = "1111222233334444"
	content, err := encodeProtectedServerID(serverID, "aa:bb:cc:dd:ee:ff")
	if err != nil {
		t.Fatalf("encodeProtectedServerID() error = %v", err)
	}

	if _, err := decodeProtectedServerID(content, "00:11:22:33:44:55"); err == nil {
		t.Fatalf("expected mismatch error when decoding with different MAC")
	}
}

func TestNormalizeServerIDPaddingAndTruncation(t *testing.T) {
	hash := []byte("hashseed")

	if got := normalizeServerID("123", hash); got != "0000000000000123" {
		t.Fatalf("normalizeServerID padding = %s", got)
	}
	if got := normalizeServerID("12345678901234567890", hash); got != "1234567890123456" {
		t.Fatalf("normalizeServerID truncation = %s", got)
	}
	if got := normalizeServerID("", hash); got == "" {
		t.Fatalf("normalizeServerID fallback should not be empty")
	}
}

func TestSanitizeDigitsAndAllDigits(t *testing.T) {
	if got := sanitizeDigits("ab12cd34"); got != "1234" {
		t.Fatalf("sanitizeDigits = %s", got)
	}
	if !isAllDigits("1234567890123456") {
		t.Fatalf("isAllDigits returned false for numeric string")
	}
	if isAllDigits("12ab") {
		t.Fatalf("isAllDigits unexpectedly true for non-numeric string")
	}
}

func TestDecodeProtectedServerIDDetectsCorruptedData(t *testing.T) {
	const serverID = "5555666677778888"
	const mac = "aa:aa:aa:aa:aa:aa"

	content, err := encodeProtectedServerID(serverID, mac)
	if err != nil {
		t.Fatalf("encodeProtectedServerID() error = %v", err)
	}

	// Corrupt the checksum line.
	corrupted := strings.Replace(content, "SYSTEM_CONFIG_DATA=\"", "SYSTEM_CONFIG_DATA=\"corrupt", 1)
	if _, err := decodeProtectedServerID(corrupted, mac); err == nil {
		t.Fatalf("expected checksum mismatch error after corrupting content")
	}
}
