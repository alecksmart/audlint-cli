# Architectural Decision Records

Load only the decisions relevant to the current task. The architecture overview remains the concise map of current behavior; these records preserve the authority, evidence, and consequences behind durable rules.

| Number | Title | Status | Record type | Scope |
| --- | --- | --- | --- | --- |
| [ADR-0001](0001-ADR-music-library-authority-and-sqlite-state.md) | Keep the music library authoritative and preserve mixed SQLite state | Accepted | Recovered | Media authority, operational catalog state, reconciliation, and database preservation |
| [ADR-0002](0002-ADR-natural-album-identity.md) | Use normalized natural album identity | Accepted | Recovered | Discovery, queues, catalog uniqueness, paths, and durable album selections |
| [ADR-0003](0003-ADR-bash5-portability.md) | Require Bash 5 with macOS and Linux portability | Accepted | Historical | Shell runtime, portable helpers, installation, and release checks |
| [ADR-0004](0004-ADR-real-resource-verification-safety.md) | Keep automated verification away from real operator resources | Accepted | Historical | Tests and verification involving libraries, databases, and mounted destinations |
| [ADR-0005](0005-ADR-source-control-safety-gate.md) | Fail closed on prohibited source-control content | Accepted | Historical | Git candidate state, release audit authority, redaction, and reviewed exceptions |
| [ADR-0006](0006-ADR-shell-python-responsibility-boundary.md) | Prefer the shell orchestration and Python computation boundary | Accepted | Contemporary | Command orchestration, shared shell policy, and Python computation ownership |
| [ADR-0007](0007-ADR-player-track-only-destinations.md) | Keep player destinations track-only | Accepted | Contemporary | Canonical player payload, destination ownership, source immutability, and explicit cleanup |
| [ADR-0008](0008-ADR-player-file-backed-rsync-snapshots.md) | Compile player snapshots into file-backed rsync rules | Accepted | Contemporary | Exact sizing and transfer membership, bounded argv, deletion semantics, and postcondition verification |
| [ADR-0009](0009-ADR-terminal-accessibility-boundary.md) | Preserve baseline terminal accessibility without a specialized screen-reader mode | Accepted | Contemporary | Keyboard access, non-color meaning, terminal safety, Unicode bounds, and assistive-technology scope |
