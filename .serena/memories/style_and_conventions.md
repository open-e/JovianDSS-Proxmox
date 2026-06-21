# Code Style and Conventions

## Perl (Plugins)
- `use strict;` and `use warnings;` mandatory
- 4-space indentation (no tabs)
- Line length: prefer 80 chars max
- Parameter unpacking: `my ( $class, $scfg, $storeid, $volname, $snap ) = @_;` (spaces inside parens)
- Double quotes for interpolation: `"${var}"`; single quotes for literals: `'string'`
- Error messages end with newline: `die "message\n";`
- Error handling: `eval { }` blocks with proper cleanup
- Array refs for shell commands (avoid interpolation for security)
- Hash formatting: fat comma with spacing: `key => value`
- Module structure: `package` declaration, `use base qw(...)`, export via `qw(:all)`
- Function naming: `<resource>_<action>` (e.g., `volume_activate`, `nas_volume_deactivate`)

## Python (jdssc CLI)
- PEP8 with type hints for function signatures
- Double quotes for strings
- Google-style docstrings for public functions
- Naming: snake_case (functions/vars), PascalCase (classes), UPPER_SNAKE_CASE (constants)
- 3-layer pattern: CLI → Driver → REST API (never CLI → REST directly)
- REST API wrappers: `<verb>_nas_<resource>` pattern
- Driver methods handle name transformation via `jcom.vname()`/`jcom.sname()`
- Use `.get()` for safe dictionary access
- Error handling: check HTTP codes (200, 201, 204 success; 500 with errno)
- Logging: INFO for operations, DEBUG for details, ERROR for failures

## Naming Conventions (JovianDSS)
- Volumes: `v_` (simple), `vh_` (human-friendly with base32)
- Snapshots: `s_` (ZFS snapshot)
- Snapshot export clones: `se_` (simple name) or `sb_` (complex name with base32)
- NAS direct mode (`-d`): use when dataset name comes from export property
- Clone naming handled in Python layer only (never in Perl)

## General (from statut-automatum)
- SOLID, KISS, YAGNI principles
- Files max ~1000 lines; single responsibility
- Logging with configurable level/file/format/output
- Fail fast; design for ease of change
- Never run `rm -Rf`
