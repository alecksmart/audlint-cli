# Draft Manifest Contract

## Artifact and lifecycle

The bootstrap route is:

```text
audlint-analyze-corpus.sh --bootstrap CORPUS_ROOT
```

It writes one deterministic review artifact:

```text
_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest-review-draft.json
```

The file is a schema-version-1 manifest skeleton, not canonical R3 evidence. Bootstrap publishes it atomically and fails if that path already exists, so rerunning discovery cannot erase review work. The operator may preserve or rename a prior draft before intentionally generating a new one.

## Draft shape

The draft uses the existing R3.1 top-level and entry structure. It adds no bootstrap metadata fields. Required human-owned fields are JSON `null`; this is deliberate invalid input until review completes.

```json
{
  "corpus_id": null,
  "corpus_revision": null,
  "entries": [
    {
      "album_path": "real/example-case",
      "case_class": null,
      "category": "real",
      "expected_decision": null,
      "expected_fake_upscale": null,
      "expected_source_profile": null,
      "expected_target_profile": null,
      "files": [
        {
          "bytes": 123,
          "channels": 2,
          "codec": "flac",
          "container": "flac",
          "duration": 1.0,
          "path": "real/example-case/track.flac",
          "role": "audio",
          "sample_rate": 44100,
          "sha256": "<lowercase SHA-256>"
        }
      ],
      "generation_recipe": null,
      "id": null,
      "provenance": null,
      "trust": null
    }
  ],
  "generated_at_utc": "<RFC 3339 UTC discovery time>",
  "schema_version": 1
}
```

`bit_depth` is present only when the objective probe supplies a meaningful positive value. `expected_analysis_mode` is absent unless a reviewer chooses to add it.

## Ownership matrix

| Field or decision | Bootstrap may populate | Human review requirement |
| --- | --- | --- |
| `schema_version`, `generated_at_utc` | Fixed schema value and discovery time | Confirm the draft belongs to the intended review run. |
| `album_path`, candidate grouping, array order | Deterministic safe root-relative suggestions | Confirm, merge, split, remove, or reorder candidates as needed. |
| `category` | Mechanical mapping from the approved `real`, `fake`, or `edge_cases` path families; otherwise `null` | Confirm or correct it. |
| `files[].path`, `sha256`, `bytes` | Safe path enumeration, hashing, and size | Confirm the declared file set belongs to the case. R3.1 rechecks every value. |
| `files[].role` | Mechanical `audio`, `cue`, or supporting-file suggestion | Confirm or correct the role. |
| Audio container, codec, sample rate, bit depth, channels, duration | Shared objective media probing | Do not replace these with analyzer output; R3.1 refreshes and validates them. |
| `corpus_id`, `corpus_revision`, entry `id`, `case_class` | `null` only | Supply stable identity and reviewed coverage classification. |
| Expected source/target profile, decision, fake-upscale value, optional analysis mode | Never | Establish independently and supply canonical reviewed values. |
| `provenance`, reviewer identity, review date, reviewed fields | Never | Supply the complete existing R3.1 provenance object. |
| `trust` | Never, including no automatic `weak` default | Choose literal `trusted` or `weak` under existing R3.1 rules. |
| `generation_recipe` | Never | Remove the `null` key for independently sourced cases; replace it with the complete existing R3.1 recipe object for synthetic derivatives. |

Candidate grouping is assistance, not identity. Discovery proposes one candidate for each directory containing directly recognized audio or CUE media, orders candidates and files by normalized root-relative path, and reports unassigned regular files in command diagnostics. Nested candidate directories remain separate suggestions until a human deliberately merges them.

## Review to strict inventory

1. Preserve the draft as the review record or work on a copy.
2. Confirm the supplied corpus root, candidate grouping, category, file set, and roles.
3. Fill stable corpus and entry identities plus `case_class`.
4. Fill every expected value from evidence independent of current Audlint output.
5. Fill complete provenance, named reviewer, UTC review date, reviewed-field list, and literal trust.
6. For each synthetic case, replace `generation_recipe: null` with the complete R3.1 recipe object. For every independently sourced case, remove the key.
7. Add `expected_analysis_mode` only when it is an intentional reviewed expectation.
8. Run the existing command unchanged:

   ```text
   audlint-analyze-corpus.sh --inventory CORPUS_ROOT REVIEWED_DRAFT.json
   ```

R3.1 remains the acceptance gate. It rejects any remaining `null`, incomplete provenance, invalid trust, unsafe path, stale checksum or size, invalid media fact, incomplete synthetic recipe, or other schema violation. On success it writes the existing canonical `corpus-manifest.json`; R3.1A never writes that file.

## Read-only boundary

Discovery resolves the supplied root before walking it, uses `lstat` without following symlinks, reads regular files only for hashing and objective probing, and writes temporary or stable output only outside the corpus root. Symlinks, path escapes, unsupported special entries, probe failures, or source changes make the run nonzero and prevent draft publication.

Pre/post evidence compares the complete supplied fixture tree by normalized path, file type, size, permission bits, modification time, status-change time, regular-file checksum, and symlink target where applicable. Access time is excluded because reads may advance it. The same contract applies when an operator later authorizes `/Volumes/Music/Tests`: it remains read-only input and receives no generated artifact.
