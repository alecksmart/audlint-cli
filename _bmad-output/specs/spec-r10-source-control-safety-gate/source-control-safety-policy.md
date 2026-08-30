# Source-Control Safety Policy

This companion is the complete version-1 contract for SPEC-r10-source-control-safety-gate.

## Interfaces and Make ordering

| Invocation | Contract |
| --- | --- |
| bin/audlint-source-audit.sh | Authoritative audit. No arguments. |
| bin/audlint-source-audit.sh --prospective | Non-authoritative complete-index audit. |
| bin/audlint-source-audit.sh --help | Fixed usage; no repository access. |
| make source-audit | Zero-argument authoritative command. |

Unknown, repeated, or combined arguments are AUDIT_USAGE and exit 2. Help prints exactly “Usage: bin/audlint-source-audit.sh [--prospective|--help]” plus one newline to stdout, leaves stderr empty, and exits 0.

The script finds the physical repository containing itself, verifies that directory is the Git top level, and audits it from any caller directory. It is developer tooling; make install and make relink exclude it.

make test remains exactly test-core plus test-legacy and never runs the audit. make check retains lint, formatting, Bash 5 consistency, and make test; only after make test succeeds does it invoke make source-audit. Normal and parallel Make preserve that order, and an earlier failure prevents the audit.

## Indexed authority

The only runtime authorities are repository-root paths in the real index:

- .audlint-source-audit-policy.json is required as exactly one stage-0 blob, mode 100644.
- .audlint-source-audit-allowlist.json is optional; when present it has the same index contract.

Each authority has a corresponding contained worktree path whose complete bytes equal the indexed blob. Every parent is a real directory and the final entry is a regular non-symlink file opened without following links. Missing policy, another index stage, intent-to-add, wrong mode, symlink, non-regular or missing worktree copy, or differing bytes exits 2. Policy failures use AUDIT_POLICY_MISSING or AUDIT_POLICY_INVALID; allowlist failures use AUDIT_ALLOWLIST_INVALID. An allowlist absent from the index must be absent from the worktree and means zero exceptions.

Runtime bytes always come from the index. The same policy and allowlist apply to HEAD, INDEX, both worktree sources, and prospective mode. An older authority blob in HEAD is only a candidate. There is no override.

### Bootstrap and allowlist lifecycle

Bootstrap requires a complete version-1 policy staged as mode 100644 with a byte-identical worktree copy. An unstaged policy yields AUDIT_POLICY_MISSING. A valid first staged policy is authoritative before it exists in HEAD.

A reviewed allowlist addition or modification becomes authoritative as soon as its stage-0 blob and worktree copy match. Its exact entries may suppress unchanged exemptible occurrences in HEAD, index, or worktree sources before the allowlist commit exists in HEAD; this prevents remediation deadlock. A staged removal means no exceptions and requires worktree absence. An unstaged removal, worktree-only addition, or byte mismatch is invalid. After commit, the unchanged index blob remains authority.

The audit captures each authority's index identity, worktree descriptor identity, length, and SHA-256 digest. Phase 7 repeats every check. Appearance, disappearance, replacement, mode change, byte change, or index mutation is AUDIT_STATE_CHANGED.

## Implementation-enforced security floor

Version 1 separates:

1. fixed implementation algorithms for matching, parsing, normalization, framing, and order;
2. immutable mandatory rules and minimum catalog members;
3. validated policy additions under fixed declarative primitives; and
4. new semantics, which require reviewed code and schema_version 2 when the data contract changes.

Policy cannot disable a rule, replace an algorithm, change a fixed limit, or remove or narrow a mandatory member. Missing or altered mandatory values are AUDIT_POLICY_INVALID.

Policy and allowlist are UTF-8 JSON without BOM. Parsing preserves ordered member pairs and rejects duplicate keys at every object level before object construction. Unknown fields are invalid; booleans are not integers.

### Exact policy schema

The exact top-level fields are:

schema_version, protected_paths, artifact_extensions, artifact_basenames, credential_basename_primitives, artifact_signatures, private_key_primitives, credential_names, provider_token_primitives, placeholders, placeholder_template_primitives, machine_path_primitives, metadata_fields, and limits.

| Field | Classification |
| --- | --- |
| schema_version | Exact integer 1. |
| protected_paths | Validated superset; fixed repository-prefix primitive. |
| artifact_extensions | Validated per-rule superset; fixed raw-basename suffix primitive. |
| artifact_basenames | Validated per-rule superset; fixed raw-basename equality primitive. |
| credential_basename_primitives | Exact primitive-ID array. |
| artifact_signatures | Exact per-rule primitive-ID arrays. |
| private_key_primitives | Exact primitive-ID array. |
| credential_names | Validated superset; fixed normalized-key suffix primitive. |
| provider_token_primitives | Exact primitive-ID array. |
| placeholders | Exact nonempty literal array. |
| placeholder_template_primitives | Exact primitive-ID array; supersedes placeholder_patterns. |
| machine_path_primitives | Exact primitive-ID array. |
| metadata_fields | Validated per-group superset; fixed normalized-field equality. |
| limits | Exact fixed-limit object. |

No version-1 field contains or executes a regular expression. An ID maps only to reviewed implementation code.

Additions obey strict grammars. Protected prefixes are printable-ASCII, nonempty, repository-relative slash paths ending in slash, with no glob, empty, dot, dot-dot, backslash, NUL, or leading slash component. Extensions are unique lowercase printable-ASCII values 2–32 bytes beginning with dot. Basenames are unique lowercase printable-ASCII values 1–64 bytes without separators or whitespace. Credential names match lowercase letter followed by at most 31 lowercase letters or digits. Metadata names match lowercase letter followed by at most 63 lowercase letters, digits, or underscores. Additive strings are scanned by all applicable fixed secret, URL, machine-path, and metadata-storage checks before acceptance.

### Mandatory catalog

protected_paths contains _bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/ and may only be extended.

Mandatory extensions are:

- SC-ART-001: .flac, .mp3, .m4a, .aac, .opus, .ogg, .oga, .wav, .aif, .aiff, .alac, .wma, .ape, .wv, .dsf, .dff, .mp4, .mkv, .mov, .avi, .webm, .jpg, .jpeg, .png, .gif, .webp, .tif, .tiff, .bmp, .heic.
- SC-ART-002: .sqlite, .sqlite3, .db, .db3, .mdb, .accdb, .sql, .dump, .sqlite-journal, .sqlite-wal, .sqlite-shm.
- SC-ART-003: .pem, .key, .p12, .pfx, .jks, .keystore, .kdbx.
- SC-ART-004: .tar.gz, .tar.bz2, .tar.xz, .zip, .tar, .tgz, .gz, .bz2, .xz, .7z, .rar.

artifact_basenames.SC-ART-003 contains credentials, credentials.json, and service-account.json; the other mandatory basename arrays are empty. credential_basename_primitives is exactly ssh-private-key-basename-v1 and dotenv-basename-v1. The first matches the four standard id_ private-key basenames for RSA, DSA, ECDSA, and ED25519. The second matches .env or .env. plus a suffix except exact example, sample, or template.

artifact_signatures maps to exact IDs:

- SC-ART-001: flac-v1, ogg-v1, id3-v1, mpeg-audio-v1, aac-adts-v1, wave-v1, avi-v1, webp-v1, aiff-v1, png-v1, jpeg-v1, gif-v1, bmp-v1, tiff-v1, matroska-v1, iso-bmff-v1, dsf-v1, dff-v1.
- SC-ART-002: sqlite-v1.
- SC-ART-003: empty.
- SC-ART-004: zip-v1, gzip-v1, bzip2-v1, xz-v1, sevenzip-v1, rar-v1, tar-v1.

Policy stores only IDs. Exact byte clauses are:

- flac-v1 0:664c6143; ogg-v1 0:4f676753; id3-v1 0:494433.
- mpeg-audio-v1 0:ffe0 masked ffe0; aac-adts-v1 0:fff0 masked fff0.
- wave-v1 0:52494646 and 8:57415645; avi-v1 the same first clause and 8:41564920; webp-v1 the same first clause and 8:57454250.
- aiff-v1 0:464f524d and offset 8 equal to 41494646 or 41494643.
- png-v1 0:89504e470d0a1a0a; jpeg-v1 0:ffd8ff; gif-v1 offset 0 equal to 474946383761 or 474946383961.
- bmp-v1 0:424d; tiff-v1 offset 0 equal to 49492a00 or 4d4d002a.
- matroska-v1 0:1a45dfa3; iso-bmff-v1 4:66747970; dsf-v1 0:44534420; dff-v1 0:46524d38 and 12:44534420.
- sqlite-v1 0:53514c69746520666f726d6174203300.
- zip-v1 offset 0 equal to 504b0304, 504b0506, or 504b0708; gzip-v1 0:1f8b; bzip2-v1 0:425a68; xz-v1 0:fd377a585a00.
- sevenzip-v1 0:377abcaf271c; rar-v1 offset 0 equal to 526172211a0700 or 526172211a070100; tar-v1 257:7573746172.

Offsets and hex are bytes, conjunctions require every clause, and all end inside the signature window. Extension and signature evidence deduplicates once per artifact rule.

private_key_primitives is exactly pem-private-v1, pem-encrypted-private-v1, pem-rsa-private-v1, pem-ec-private-v1, pem-dsa-private-v1, openssh-private-v1, and pgp-private-block-v1. Their labels are respectively PRIVATE KEY, ENCRYPTED PRIVATE KEY, RSA PRIVATE KEY, EC PRIVATE KEY, DSA PRIVATE KEY, OPENSSH PRIVATE KEY, and PGP PRIVATE KEY BLOCK. Each matches an ASCII line built from five hyphens, BEGIN plus one space, its label, and five hyphens. Complete matching fixtures are not tracked.

credential_names contains password, passwd, passphrase, token, apikey, accesskey, secret, clientsecret, and privatekey.

provider_token_primitives is exactly:

- aws-access-key-v1: boundary, AKIA, exactly 16 uppercase ASCII letters or digits, boundary.
- github-legacy-token-v1: boundary, gh, one registered type letter, underscore, 36–255 ASCII alphanumerics, boundary.
- github-fine-grained-v1: boundary, fixed fragments github_ and pat_, 20–255 ASCII alphanumerics or underscores, boundary.
- slack-token-v1: boundary, xox, one registered type letter, hyphen, 10–255 ASCII alphanumerics or hyphens, boundary.
- stripe-live-secret-v1: boundary, fragments sk_ and live_, 16–255 ASCII alphanumerics, boundary.
- google-api-key-v1: boundary, fragments AI and za, exactly 35 ASCII alphanumerics, underscores, or hyphens, boundary.
- generic-sk-secret-v1: boundary, sk and hyphen, 20–255 ASCII alphanumerics, underscores, or hyphens, boundary.

A boundary byte, when present, is outside that primitive's payload alphabet. Matching is bytewise ASCII.

placeholders is exactly the nonempty values example, example_only, placeholder, redacted, changeme, test, dummy, fake, and your_value_here, compared after ASCII trim and case folding. An empty assigned value is safe algorithmically and is not stored in this array.

placeholder_template_primitives is exactly shell-variable-placeholder-v1, mustache-placeholder-v1, and angle-placeholder-v1. They consume the complete trimmed scalar and respectively recognize: a dollar sign and braced 1–64 byte uppercase identifier; double braces around a 1–64 byte ASCII identifier beginning with a letter or underscore; and angle brackets around a 1–64 byte ASCII label beginning with a letter. Later bytes use only each primitive's registered identifier punctuation.

machine_path_primitives is exactly posix-user-home-v1, posix-volume-v1, posix-mount-v1, windows-user-home-v1, and unc-share-v1. POSIX forms require a boundary, slash, a registered root component, slash, a nonempty next component, and optional non-whitespace path bytes. Registered roots are Users or home; Volumes; and mnt or media. Windows user-home requires drive letter, colon, slash-or-backslash separators, Users, separators, and a nonempty user component. UNC requires two leading backslashes and nonempty server and share components. Windows is ASCII case-insensitive; POSIX is case-sensitive. These are content patterns, not symlink syntax.

metadata_fields contains artist: artist and album_artist; release: album and release; provenance: source_path, relative_path, file, track, checksum, codec, container, profile; analysis: checksum, profile, codec, decision, confidence, benchmark.

### Self-hosting behavior

Policy and allowlist remain repository candidates and receive normal path, artifact, invalid-text, and content checks subject only to the contextual schema rule below. No file-wide or directory-wide exclusion exists.

After strict schema validation, only exact detector-definition fields receive contextual interpretation: catalog members, primitive IDs, protected prefixes, and fixed limits are definitions, not evidence for the rule they configure. Unknown fields and arbitrary prose cannot exist. Additions undergo the validation and scanning above. The allowlist has no free-text field.

Focused proof removes and changes mandatory data, substitutes primitives, duplicates nested keys, adds unknown fields, attempts token-like additive storage, and places unrelated evidence outside contextual fields. None may weaken the gate or hide another candidate's evidence.

Documentation is normally scanned and uses split or schematic signatures where sufficient; an unavoidable complete match needs an exact reviewed occurrence exception. No documentation path is excluded. Tracked tests assemble positive signatures at runtime from nonmatching fragments. Matching fixtures exist only inside temporary repositories. Test paths are not excluded.

### Allowlist schema

The optional document has exactly schema_version and entries. Version is integer 1. Each of at most 4096 entries has exactly rule, path, fingerprint, reason_code, and review_ref. rule is exemptible; path is the exact encoded path below; fingerprint is sha256: plus 64 lowercase hexadecimal digits. reason_code is one of documentation-example, synthetic-test-source, repository-asset, or reviewed-false-positive. review_ref is 1–64 ASCII bytes beginning with uppercase letter or digit and continuing with uppercase letters, digits, dot, underscore, slash, or hyphen.

Unknown fields, free text, duplicate keys or tuples, malformed values, unknown rules, and SC-PATH-001, SC-PATH-002, or SC-PATH-003 entries are AUDIT_ALLOWLIST_INVALID. Matching is exact rule, path, and fingerprint. Source label is excluded. There is no rule-only, path-only, glob, directory, generated, or automatic baseline.

## Sources and ignore authority

| Order | Source | Authoritative | Prospective |
| ---: | --- | --- | --- |
| 1 | HEAD | Complete tree; unborn is empty. | Not scanned. |
| 2 | INDEX | Complete stage-0 snapshot. | Complete stage-0 snapshot. |
| 3 | WORKTREE_TRACKED | Tracked paths differing from index. | Not scanned. |
| 4 | WORKTREE_UNTRACKED | Effectively non-ignored candidates. | Not scanned. |

Sources are independent. Unsafe HEAD remains exit 1 after staged repair or deletion. Equal evidence can have the same fingerprint under different source labels.

SC-PATH-002 uses same-source repository-owned .gitignore bytes: HEAD tree blobs, index blobs, or contained worktree files. Normal repository precedence, scope, slash rules, last match, and negation apply. Local and global excludes never create SC-PATH-002.

Untracked enumeration separately uses effective Git ignore behavior, including local and global excludes. An effectively ignored untracked path is never opened, named, fingerprinted, or reported. Once force-added, it is an index candidate.

## Git routing and ordered phases

Phase 2 rejects these variables when set: GIT_DIR, GIT_WORK_TREE, GIT_INDEX_FILE, GIT_COMMON_DIR, GIT_OBJECT_DIRECTORY, GIT_ALTERNATE_OBJECT_DIRECTORIES, GIT_NAMESPACE, GIT_REPLACE_REF_BASE, GIT_QUARANTINE_PATH, GIT_SHALLOW_FILE, GIT_CEILING_DIRECTORIES, GIT_DISCOVERY_ACROSS_FILESYSTEM, GIT_EXEC_PATH, GIT_CONFIG, GIT_CONFIG_PARAMETERS, GIT_CONFIG_COUNT, every numbered GIT_CONFIG_KEY_n and GIT_CONFIG_VALUE_n, GIT_CONFIG_GLOBAL, GIT_CONFIG_SYSTEM, GIT_CONFIG_NOSYSTEM, GIT_GLOB_PATHSPECS, GIT_NOGLOB_PATHSPECS, GIT_LITERAL_PATHSPECS, and GIT_ICASE_PATHSPECS.

Child processes set GIT_NO_REPLACE_OBJECTS=1, GIT_OPTIONAL_LOCKS=0, LC_ALL=C, LANG=C, TZ=UTC, and deterministic Python hashing. Normal user configuration is consulted only for effective untracked ignores. No alias, hook, filter, pager, editor, credential helper, network transport, or external diff executes.

Version 1 accepts only a non-bare main worktree whose physical root contains real .git, .git/index, and .git/objects paths. A .git file, distinct common directory, core.worktree redirect, split index, nonempty objects/info/alternates, replacement refs, or required administrative path outside root is AUDIT_UNSUPPORTED_REPOSITORY. Linked worktrees are rejected. A locked or missing index, unmerged stage, intent-to-add, unsafe sparse state, or inconsistent object access is AUDIT_GIT_STATE.

Later phases never run after failure; earliest phase wins:

| Phase | Work | Behavior on error |
| ---: | --- | --- |
| 1 | Arguments/help | Help returns; invalid input stops at first fixed check. |
| 2 | Repository/Git environment | First error in the listed environment order, then repository-shape order. |
| 3 | Indexed authority bootstrap | First of policy index, policy worktree, policy parse/floor, allowlist index/worktree, allowlist parse. |
| 4 | Snapshot/Git state | First of HEAD, real index, ignore authorities, worktree state. |
| 5 | Enumeration and per-namespace collisions | Collect all safely detectable metadata errors, deduplicate, sort; limit replaces all. |
| 6 | Candidate scan | Deterministic candidate order; first execution error stops scanning. |
| 7 | Authority/snapshot revalidation | First of policy, allowlist, HEAD, index, ignore, candidate list, worktree identity; discard findings. |
| 8 | Deterministic output | First serialization or buffer-limit error becomes fixed exit 2. |

Phase-5 errors sort by source order, raw path, then ID. Phase-6 first error follows candidate order. No phase emits raw tool output.

## Paths, symlinks, collision namespaces, and precedence

Git paths remain raw bytes for matching, identity, and sorting. JSON path is repository-relative percent encoding: ASCII letters, digits, hyphen, dot, underscore, tilde, and slash remain; every other byte, including percent and backslash, becomes uppercase %HH. Allowlist paths use this form.

Collision checks run independently in the complete HEAD namespace, complete stage-0 index namespace, and effective worktree namespace. Effective worktree starts from index, removes ordinary tracked deletions, replaces materialized tracked entries with current path and kind, retains absent skip-worktree paths, and adds eligible untracked paths. HEAD and index never cross-collide.

Every explicit path and implicit directory participates. Valid UTF-8 components use vendored Unicode 14.0 tables for NFC, full casefold, then NFC. Invalid-UTF-8 components lowercase ASCII A–Z and preserve other bytes. Equal full keys from distinct raw paths, or a file key prefixing another path, is AUDIT_PATH_COLLISION.

Candidates validate state, then apply SC-PATH-001, SC-PATH-002, symlink handling, resource limits, artifact rules, and content rules. Protected wins over ignored. Either boundary finding stops the candidate before blob or worktree content, signature, or digest access. Any artifact finding prevents text scanning.

Git modes 100644 and 100755 are regular; 120000 is link text. Worktree regular files map to 100755 if any POSIX execute bit is set, else 100644; symlinks map to 120000. Gitlinks and other modes, FIFOs, sockets, and devices are AUDIT_UNSUPPORTED_ENTRY and never entered. Contained worktree traversal uses non-symlink directory descriptors and no-follow opens; identity, kind, size, and mutation are checked around reads.

Symlink targets are raw bytes and never dereferenced. Empty, NUL-containing, or otherwise unevaluable bytes are AUDIT_SYMLINK_INVALID. Leading slash is absolute. Relative resolution begins at the containing directory; split only on slash, collapse repeats and dot, and apply dot-dot lexically. Root underflow or an outside final location produces SC-PATH-003. Backslash is ordinary. Drive and UNC spellings are content patterns only.

## Rules, structured values, and spans

| Rule | Unsafe condition | Fixed redacted description |
| --- | --- | --- |
| SC-PATH-001 | Protected generated prefix is tracked. | protected generated output is tracked |
| SC-PATH-002 | Same-source repository rule ignores a tracked path. | repository-ignored path is tracked |
| SC-PATH-003 | Link target is absolute or lexically outside root. | symlink target is outside repository boundary |
| SC-PATH-004 | Machine-path primitive matches content. | machine-specific absolute path detected |
| SC-ART-001 | Path or signature identifies media. | prohibited media artifact |
| SC-ART-002 | Path or signature identifies database data. | prohibited database artifact |
| SC-ART-003 | Path identifies credential or key storage. | prohibited credential artifact |
| SC-ART-004 | Path or signature identifies an archive. | prohibited archive artifact |
| SC-ART-005 | Bytes have forbidden BOM, NUL, or invalid UTF-8. | opaque or unsupported text artifact |
| SC-CRED-001 | Private-key begin primitive matches. | private-key signature detected |
| SC-CRED-002 | Parsed credential key has non-placeholder scalar. | credential assignment detected |
| SC-CRED-003 | Provider-token primitive matches. | provider credential signature detected |
| SC-CRED-004 | URI authority embeds colon-bearing user information. | embedded URL credential detected |
| SC-META-001 | Record combines artist, release, and provenance. | private media metadata record detected |
| SC-META-002 | Record combines media path and analysis evidence. | private media manifest record detected |

IDs are never repurposed. Only SC-PATH-001 through 003 are non-exemptible.

Text is UTF-8 with optional leading UTF-8 BOM. Unsupported BOM, NUL, or invalid UTF-8 after signatures is SC-ART-005. Candidate totals include BOM and terminators. LF and CRLF terminate a physical line; bare CR is data. Line limits exclude terminators and leading BOM. Logical-record limits include quotes, delimiters, escapes, and continuation newlines, but exclude a terminating newline and leading BOM.

Structured extension authority is ASCII-lowercased basename suffix: .json, .jsonl, .ndjson, .csv, .tsv, .md, and .markdown. Renamed structured content uses generic physical lines; v1 does no sniffing.

JSON preserves duplicate pairs for candidate scanning; every object is a record in token order. Depth is zero before input and every array or object, including root, increments it. JSONL has one nonblank physical-line JSON value. CSV/TSV use Python csv strict mode, first logical record headers, doubled quotes, and quoted multiline fields; empty or duplicate normalized headers fail. Malformed structured syntax is AUDIT_PARSE_FAILED.

Markdown tables are parsed only outside fences. An opener has zero to three spaces and at least three identical backticks or tildes; a close has the same character at least opener length and then only whitespace. Raw content rules still scan fenced content. A pipe preceded by an odd backslash run is literal; all other pipes separate, including inline-code pipes. Optional edge separators do not add cells. A table has at least two header cells and an equal-width separator row. Each separator cell is whitespace, optional colon, at least three hyphens, optional colon, whitespace, with nothing else. Data rows with a pipe must keep width; cells never span lines. A begun malformed table is AUDIT_PARSE_FAILED.

Field names trim ASCII whitespace/quotes, lowercase ASCII, and turn hyphens into underscores. Credential keys also remove dot, underscore, and hyphen, then equal or end with a credential name.

SC-CRED-002 assesses direct key/scalar pairs in JSON/JSONL, including duplicates and minified objects; header/value pairs in CSV/TSV; and Markdown table pairs. Other text uses the physical-line assignment grammar: optional whitespace and export, ASCII or quoted key, equals or colon, then value. JSON strings decode; numbers keep validated lexical form; booleans become lowercase text; null has no value. Other formats use decoded field text. Empty after ASCII trim, literal placeholders, and full template placeholders are safe. Multiline structured values remain one value and report their starting line.

SC-CRED-004 recognizes a bytewise ASCII scheme beginning with a letter and continuing with letters, digits, plus, dot, or hyphen, followed by colon and two slashes. Authority ends before ASCII whitespace, slash, question mark, or hash. User information before the last at-sign must contain a colon; the value after its first colon uses the same empty and placeholder rules. Percent escapes are not decoded.

SC-META-001 artist and release values are nonempty non-placeholder strings. Provenance is such a string or finite JSON number. SC-META-002 needs a nonempty non-placeholder string with at least two slash-separated components ending in a media extension plus analysis evidence of the same string-or-finite-number type. Null, empty, placeholder, boolean, container-only, and non-finite values do not qualify. Each metadata rule emits at most once per record using the earliest qualifying values in token order.

Every content/signature match has a zero-based half-open byte span within its physical line or logical record, excluding leading BOM and terminating newline. Value spans include quotes, escapes, padding, and continuation newlines but exclude key and delimiter. Identical rule/start/end spans deduplicate; tied primitives keep lowest ASCII ID. Remaining spans sort by start, end, primitive ID, then receive one-based ordinals. Nested and partially overlapping spans remain distinct. The diagnostic line contains the start byte.

## Limits and fingerprints

Repository metadata previously showed 654 tracked blobs, maximum 622,256 bytes, p99 73,426 bytes, and none over 1 MiB. Fixed limits are:

| Key | Value |
| --- | ---: |
| policy_bytes / allowlist_bytes | 262144 / 2097152 |
| bootstrap_json_depth | 32 |
| policy_entries / allowlist_entries | 4096 / 4096 |
| candidate_count | 100000 |
| path_bytes / aggregate_path_bytes | 4096 / 16777216 |
| aggregate_candidate_bytes / candidate_bytes | 268435456 / 8388608 |
| line_bytes / record_bytes / json_nesting | 65536 / 1048576 / 64 |
| signature_prefix_bytes / read_chunk_bytes | 4096 / 65536 |
| finding_count / error_count / diagnostic_bytes | 16384 / 1024 / 16777216 |

Bootstrap limits apply before policy. policy_entries counts every member pair and array element below root. Candidate and aggregate path counts treat each source occurrence separately. Aggregate candidate bytes sum every candidate eligible for content or link-byte reading after boundary short circuits; repeated source bytes count repeatedly. Finding count is before exceptions. Diagnostic bytes include canonical JSONL newlines. Any breach emits only AUDIT_LIMIT_EXCEEDED plus error summary on stderr, discards findings/errors, leaves stdout empty, and exits 2.

Fingerprints SHA-256 six eight-byte-length-framed fields: rule ID; raw relative path; kind token 100644, 100755, or 120000; complete content SHA-256 or path-state digest; unsigned record/line identity; unsigned occurrence ordinal. Source and matched value are excluded.

Path-state digests use the same framing:

- SC-PATH-001: protected-path-state-v1, mode, exact matched protected prefix.
- SC-PATH-002: ignored-path-state-v1, mode, and decisive ignore identity. That identity frames same-source .gitignore raw path, complete SHA-256, one-based rule ordinal, and raw decisive rule bytes.
- SC-PATH-003: symlink-path-state-v1, mode 120000, and SHA-256 of raw target bytes.

These identities are mandatory; Git object IDs are never optional substitutes. Path-only fingerprints are diagnostic and remain non-exemptible.

## Diagnostics and exits

Normal stdout is deterministic JSONL. Finding keys are exactly record, source, rule, path, line, description, fingerprint. Findings sort by source order, raw path, rule, null-before-numbered line, record identity, ordinal, fingerprint. The last record is a summary with record, status, findings, errors. Stderr is empty for exit 0 or 1.

Exit 2 discards findings and leaves stdout empty. Stderr contains fixed redacted error records with record, error, source, path, description, then one error summary. No output contains matched values, matching lines, file bytes, key or token material, detected machine paths, absolute repository paths, parser/exception text, or raw Git, Python, filesystem, or OS messages.

| Error | Fixed description |
| --- | --- |
| AUDIT_USAGE | command arguments are invalid |
| AUDIT_NOT_REPOSITORY | repository resolution failed |
| AUDIT_GIT_ENVIRONMENT | Git environment is not permitted |
| AUDIT_UNSUPPORTED_REPOSITORY | repository layout is unsupported |
| AUDIT_POLICY_MISSING | indexed policy is missing |
| AUDIT_POLICY_INVALID | indexed policy is invalid |
| AUDIT_ALLOWLIST_INVALID | indexed allowlist is invalid |
| AUDIT_GIT_STATE | Git state cannot be audited safely |
| AUDIT_UNSUPPORTED_ENTRY | repository entry type is unsupported |
| AUDIT_PATH_COLLISION | repository paths collide on a supported filesystem |
| AUDIT_SYMLINK_INVALID | symlink target cannot be evaluated safely |
| AUDIT_STATE_CHANGED | repository state changed during audit |
| AUDIT_LIMIT_EXCEEDED | audit resource limit was exceeded |
| AUDIT_READ_FAILED | candidate could not be read safely |
| AUDIT_PARSE_FAILED | candidate structured text is invalid |
| AUDIT_INTERNAL | internal audit failure |

Exit 0 means clean selected sources or help; exit 1 means findings without errors; exit 2 means any usage, authority, policy, Git, containment, limit, mutation, parse, read, or execution error.

## Adoption and verification

An earlier static observation against HEAD fd32ca40473f925eda531b3974af574472a5fd36 estimated 31 machine-path matches and one raster asset. It predates staged authority and completed implementation, is provisional only, and is not R10 acceptance evidence. No disposition is invented or preapproved here.

After policy, allowlist, implementation, documentation, and tests are staged, maintainers run a new authoritative redacted audit across every source and record an exact reviewed disposition for every finding: remove/repair, narrow a proven false positive with focused tests, or add one exact exemptible occurrence. It never enumerates or reads ignored private artifacts.

Temporary-repository tests with synthetic strings cover: clean; every source; blocking HEAD and unborn HEAD; prospective index only; ignored exclusion and force-add; protected short circuit; policy bootstrap/mode/stage/symlink/mismatch/mutation; allowlist add/modify/remove/post-commit and invalidation; mandatory-floor and duplicate-key attacks; self-hosting; Git environment/object/index/linked-worktree routing; symlink lexical cases; independent collision namespaces and rename cases; modes and path-state identity; every rule primitive and near miss; minified structured credentials; metadata scalar qualification; BOM/terminator/record/depth/Markdown/extension boundaries; duplicate/overlap/span order; every exact resource boundary; redaction and phase precedence; deletions/sparse/gitlinks/special files/mutation; deterministic ordering; macOS/Linux Bash 5 portability; Make ordering; installation exclusion; new staged adoption; and complete make check.

Tracked tests assemble complete positive signatures from nonmatching fragments and create matches only in temporary repositories. Focused tests are the iteration gate; complete make check is final proof. No hook, prospective run, broad baseline, network, private fixture, R3 behavior change, or specialist-scanner replacement is accepted as a substitute.
