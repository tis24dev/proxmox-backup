package utils

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFileExists(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a test file
	testFile := filepath.Join(tmpDir, "test.txt")
	if err := os.WriteFile(testFile, []byte("test"), 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	// Test file exists
	if !FileExists(testFile) {
		t.Error("FileExists should return true for existing file")
	}

	// Test file doesn't exist
	if FileExists(filepath.Join(tmpDir, "nonexistent.txt")) {
		t.Error("FileExists should return false for nonexistent file")
	}

	// Test directory (should return false for directories)
	if FileExists(tmpDir) {
		t.Error("FileExists should return false for directories")
	}
}

func TestDirExists(t *testing.T) {
	tmpDir := t.TempDir()

	// Create a subdirectory
	testDir := filepath.Join(tmpDir, "testdir")
	if err := os.Mkdir(testDir, 0755); err != nil {
		t.Fatalf("Failed to create test directory: %v", err)
	}

	// Test directory exists
	if !DirExists(testDir) {
		t.Error("DirExists should return true for existing directory")
	}

	// Test directory doesn't exist
	if DirExists(filepath.Join(tmpDir, "nonexistent")) {
		t.Error("DirExists should return false for nonexistent directory")
	}

	// Create a file
	testFile := filepath.Join(tmpDir, "test.txt")
	if err := os.WriteFile(testFile, []byte("test"), 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	// Test file (should return false for files)
	if DirExists(testFile) {
		t.Error("DirExists should return false for files")
	}
}

func TestEnsureDir(t *testing.T) {
	tmpDir := t.TempDir()

	// Test creating new directory
	newDir := filepath.Join(tmpDir, "new", "nested", "dir")
	if err := EnsureDir(newDir); err != nil {
		t.Errorf("EnsureDir failed: %v", err)
	}

	if !DirExists(newDir) {
		t.Error("Directory should have been created")
	}

	// Test with existing directory (should not error)
	if err := EnsureDir(newDir); err != nil {
		t.Errorf("EnsureDir should not error on existing directory: %v", err)
	}
}

func TestComputeSHA256(t *testing.T) {
	tmpDir := t.TempDir()

	// Create test file with known content
	testFile := filepath.Join(tmpDir, "test.txt")
	content := []byte("hello world")
	if err := os.WriteFile(testFile, content, 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	hash, err := ComputeSHA256(testFile)
	if err != nil {
		t.Errorf("ComputeSHA256 failed: %v", err)
	}

	// Known SHA256 of "hello world"
	expectedHash := "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9"
	if hash != expectedHash {
		t.Errorf("ComputeSHA256 = %s; want %s", hash, expectedHash)
	}

	// Test nonexistent file
	_, err = ComputeSHA256(filepath.Join(tmpDir, "nonexistent.txt"))
	if err == nil {
		t.Error("ComputeSHA256 should error for nonexistent file")
	}
}

func TestGetFileSize(t *testing.T) {
	tmpDir := t.TempDir()

	// Create test file with known size
	testFile := filepath.Join(tmpDir, "test.txt")
	content := []byte("12345678901234567890") // 20 bytes
	if err := os.WriteFile(testFile, content, 0644); err != nil {
		t.Fatalf("Failed to create test file: %v", err)
	}

	size, err := GetFileSize(testFile)
	if err != nil {
		t.Errorf("GetFileSize failed: %v", err)
	}

	if size != 20 {
		t.Errorf("GetFileSize = %d; want 20", size)
	}

	// Test nonexistent file
	_, err = GetFileSize(filepath.Join(tmpDir, "nonexistent.txt"))
	if err == nil {
		t.Error("GetFileSize should error for nonexistent file")
	}
}

func TestAbsPath(t *testing.T) {
	// Test with relative path
	absPath, err := AbsPath(".")
	if err != nil {
		t.Errorf("AbsPath failed: %v", err)
	}

	if !filepath.IsAbs(absPath) {
		t.Error("AbsPath should return absolute path")
	}

	// Test with already absolute path
	testPath := "/tmp/test"
	absPath, err = AbsPath(testPath)
	if err != nil {
		t.Errorf("AbsPath failed: %v", err)
	}

	if absPath != testPath {
		t.Errorf("AbsPath(%s) = %s; want %s", testPath, absPath, testPath)
	}
}

func TestIsAbsPath(t *testing.T) {
	tests := []struct {
		name     string
		path     string
		expected bool
	}{
		{"absolute unix", "/tmp/test", true},
		{"relative dot", ".", false},
		{"relative path", "test/path", false},
		{"relative dotdot", "../test", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := IsAbsPath(tt.path)
			if result != tt.expected {
				t.Errorf("IsAbsPath(%q) = %v; want %v", tt.path, result, tt.expected)
			}
		})
	}
}
