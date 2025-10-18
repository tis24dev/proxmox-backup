# Changelog

Tutte le modifiche notevoli a questo progetto sono documentate in questo file.

Il formato è basato su [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
e questo progetto aderisce al [Semantic Versioning](https://semver.org/spec/v2.0.0.html).


## [1.1.0] - 2025-10-18 - Script Autonomo: new-install.sh

### Changed
? ****Added automatic backup before complete removal****
- Added full backup feature before complete removal of all files: allows creating a safety backup before the script fully deletes the files of the previous installation, in order to prevent accidental data loss.
- Autore: root

---

## [0.2.1] - 2025-10-11

### Added
✨ **Sistema di versioning centralizzato**
- Creato file VERSION per gestione centralizzata delle versioni
- Implementato script update-version.sh per gestione automatica versioning
- Aggiunto supporto per CHANGELOG.md automatico
- Implementato sistema di backup automatico delle versioni precedenti
- File di configurazione backup.env ora ha versione autonoma
- Script installer (install.sh, new-install.sh) hanno versioni indipendenti
- Aggiornato: script/proxmox-backup.sh, tutte le librerie lib/*.sh
- Autore: root

### Changed
- Header standardizzati per tutti i file script e librerie
- Sistema di caricamento versione migliorato in proxmox-backup.sh
- Documentazione aggiornata per nuovo sistema di versioning

### Fixed
- Rimosse versioni duplicate di SCRIPT_VERSION in più file
- Corretta gestione delle versioni per file di configurazione

---

