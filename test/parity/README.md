# Parity Test Harness

This package provides parity testing between the Bash and Go implementations of the Proxmox backup system.

## Purpose

During the incremental migration from Bash to Go, it's critical to ensure that:
1. Both implementations produce the same exit codes
2. Both implementations handle errors consistently
3. Both implementations produce equivalent results

## Usage

### Running Parity Tests

Parity tests are skipped by default in normal test runs. To run them explicitly:

```bash
# Run all parity tests
go test -v ./test/parity -run TestParity

# Run specific parity test
go test -v ./test/parity -run TestParityDryRun

# Run with timeout
go test -v -timeout 5m ./test/parity
```

### Test Scenarios

Currently implemented:
- **Dry Run Parity**: Compares dry-run execution of Bash vs Go

Planned:
- **Exit Code Parity**: Verify exit codes match for error scenarios
- **Config Parsing Parity**: Ensure both read config identically
- **Log Output Parity**: Compare log messages and format
- **Performance Parity**: Ensure Go version isn't significantly slower

## Test Structure

```
test/parity/
├── runner.go          # Core parity test runner
├── runner_test.go     # Actual parity tests
└── README.md          # This file
```

## Integration with CI/CD

These tests can be integrated into CI/CD pipelines to catch regressions:

```yaml
# Example GitHub Actions step
- name: Run Parity Tests
  run: |
    make build
    go test -v -timeout 10m ./test/parity
```

## Adding New Parity Tests

To add a new parity test:

1. Add a method to `Runner` in `runner.go` (e.g., `RunConfigTest`)
2. Add a test function in `runner_test.go` (e.g., `TestParityConfig`)
3. Document the test scenario in this README

## Notes

- Tests require both Bash and Go binaries to be available
- Tests use the real configuration file from `/opt/proxmox-backup/env/backup.env`
- Tests run in isolated contexts with timeouts to prevent hangs
- Exit code comparison is the primary success criterion
- Output comparison is informational and logged but doesn't fail tests (yet)

## Future Enhancements

- [ ] Add output diff comparison with configurable tolerance
- [ ] Add performance regression detection (e.g., Go shouldn't be >2x slower)
- [ ] Add memory usage comparison
- [ ] Add test fixtures for deterministic testing
- [ ] Add snapshot testing for log output
