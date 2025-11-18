package types

// ExitCode rappresenta i codici di uscita dell'applicazione
type ExitCode int

const (
	// ExitSuccess - Esecuzione completata con successo
	ExitSuccess ExitCode = 0

	// ExitGenericError - Errore generico non specificato
	ExitGenericError ExitCode = 1

	// ExitConfigError - Errore nella configurazione
	ExitConfigError ExitCode = 2

	// ExitEnvironmentError - Ambiente Proxmox non valido o non supportato
	ExitEnvironmentError ExitCode = 3

	// ExitBackupError - Errore durante l'operazione di backup (generico)
	ExitBackupError ExitCode = 4

	// ExitStorageError - Errore nelle operazioni di storage
	ExitStorageError ExitCode = 5

	// ExitNetworkError - Errore di rete (upload, notifiche, ecc.)
	ExitNetworkError ExitCode = 6

	// ExitPermissionError - Errore di permessi
	ExitPermissionError ExitCode = 7

	// ExitVerificationError - Errore nella verifica dell'integrità
	ExitVerificationError ExitCode = 8

	// ExitCollectionError - Errore durante la raccolta dei file di configurazione
	ExitCollectionError ExitCode = 9

	// ExitArchiveError - Errore durante la creazione dell'archivio
	ExitArchiveError ExitCode = 10

	// ExitCompressionError - Errore durante la compressione
	ExitCompressionError ExitCode = 11

	// ExitDiskSpaceError - Spazio su disco insufficiente
	ExitDiskSpaceError ExitCode = 12

	// ExitPanicError - Panic non gestito intercettato
	ExitPanicError ExitCode = 13

	// ExitSecurityError - Errori rilevati dal controllo di sicurezza
	ExitSecurityError ExitCode = 14
)

// String restituisce una descrizione testuale del codice di uscita
func (e ExitCode) String() string {
	switch e {
	case ExitSuccess:
		return "success"
	case ExitGenericError:
		return "generic error"
	case ExitConfigError:
		return "configuration error"
	case ExitEnvironmentError:
		return "environment error"
	case ExitBackupError:
		return "backup error"
	case ExitStorageError:
		return "storage error"
	case ExitNetworkError:
		return "network error"
	case ExitPermissionError:
		return "permission error"
	case ExitVerificationError:
		return "verification error"
	case ExitCollectionError:
		return "collection error"
	case ExitArchiveError:
		return "archive error"
	case ExitCompressionError:
		return "compression error"
	case ExitDiskSpaceError:
		return "disk space error"
	case ExitPanicError:
		return "panic error"
	case ExitSecurityError:
		return "security error"
	default:
		return "unknown error"
	}
}

// Int restituisce il codice di uscita come intero
func (e ExitCode) Int() int {
	return int(e)
}
