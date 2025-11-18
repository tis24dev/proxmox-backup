package types

import "time"

// ProxmoxType rappresenta il tipo di ambiente Proxmox
type ProxmoxType string

const (
	// ProxmoxVE - Proxmox Virtual Environment
	ProxmoxVE ProxmoxType = "pve"

	// ProxmoxBS - Proxmox Backup Server
	ProxmoxBS ProxmoxType = "pbs"

	// ProxmoxUnknown - Tipo sconosciuto o non rilevato
	ProxmoxUnknown ProxmoxType = "unknown"
)

// String restituisce la rappresentazione stringa del tipo Proxmox
func (p ProxmoxType) String() string {
	return string(p)
}

// CompressionType rappresenta il tipo di compressione
type CompressionType string

const (
	// CompressionGzip - Compressione gzip
	CompressionGzip CompressionType = "gz"

	// CompressionPigz - Compressione gzip parallela (pigz)
	CompressionPigz CompressionType = "pigz"

	// CompressionBzip2 - Compressione bzip2
	CompressionBzip2 CompressionType = "bz2"

	// CompressionXZ - Compressione xz (LZMA)
	CompressionXZ CompressionType = "xz"

	// CompressionLZMA - Compressione lzma classica
	CompressionLZMA CompressionType = "lzma"

	// CompressionZstd - Compressione zstd
	CompressionZstd CompressionType = "zst"

	// CompressionNone - Nessuna compressione
	CompressionNone CompressionType = "none"
)

// String restituisce la rappresentazione stringa del tipo di compressione
func (c CompressionType) String() string {
	return string(c)
}

// BackupInfo contiene informazioni su un backup
type BackupInfo struct {
	// Timestamp del backup
	Timestamp time.Time

	// Nome del file di backup
	Filename string

	// Dimensione del file in bytes
	Size int64

	// Checksum SHA256
	Checksum string

	// Tipo di compressione usata
	Compression CompressionType

	// Path completo del file
	Path string

	// Tipo di ambiente Proxmox
	ProxmoxType ProxmoxType
}

// BackupMetadata contains metadata about a backup file
// Used by storage backends to track backup files
type BackupMetadata struct {
	// BackupFile is the full path to the backup file
	BackupFile string

	// Timestamp is when the backup was created
	Timestamp time.Time

	// Size is the file size in bytes
	Size int64

	// Checksum is the SHA256 checksum of the backup file
	Checksum string

	// ProxmoxType is the type of Proxmox environment (PVE/PBS)
	ProxmoxType ProxmoxType

	// Compression is the compression type used
	Compression CompressionType

	// Version is the backup format version
	Version string
}

// StorageLocation rappresenta una destinazione di storage
type StorageLocation string

const (
	// StorageLocal - Storage locale
	StorageLocal StorageLocation = "local"

	// StorageSecondary - Storage secondario
	StorageSecondary StorageLocation = "secondary"

	// StorageCloud - Storage cloud (rclone)
	StorageCloud StorageLocation = "cloud"
)

// String restituisce la rappresentazione stringa della location
func (s StorageLocation) String() string {
	return string(s)
}

// LogLevel rappresenta il livello di logging
type LogLevel int

const (
	// LogLevelDebug - Log di debug (massimo dettaglio)
	LogLevelDebug LogLevel = 5

	// LogLevelInfo - Informazioni generali
	LogLevelInfo LogLevel = 4

	// LogLevelWarning - Avvisi
	LogLevelWarning LogLevel = 3

	// LogLevelError - Errori
	LogLevelError LogLevel = 2

	// LogLevelCritical - Errori critici
	LogLevelCritical LogLevel = 1

	// LogLevelNone - Nessun log
	LogLevelNone LogLevel = 0
)

// String restituisce la rappresentazione stringa del log level
func (l LogLevel) String() string {
	switch l {
	case LogLevelDebug:
		return "DEBUG"
	case LogLevelInfo:
		return "INFO"
	case LogLevelWarning:
		return "WARNING"
	case LogLevelError:
		return "ERROR"
	case LogLevelCritical:
		return "CRITICAL"
	case LogLevelNone:
		return "NONE"
	default:
		return "UNKNOWN"
	}
}
