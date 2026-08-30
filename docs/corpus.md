# Corpus Reference

This reference is for maintainers who build and evaluate Audlint's controlled
analyzer corpus. It is not part of normal music-library use.

## Contents

- [Bootstrap a review draft](#bootstrap-a-review-draft)
- [Inventory a reviewed manifest](#inventory-a-reviewed-manifest)
- [Evaluate a corpus](#evaluate-a-corpus)

## Bootstrap a review draft

To prepare a new manifest for review, use the read-only bootstrap command with
an explicit corpus root:

```bash
audlint-analyze-corpus.sh --bootstrap /path/to/corpus
```

It atomically creates
`_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest-review-draft.json`
only if that file does not already exist. The draft has objective file hashes,
sizes, audio facts, candidate directory suggestions, and mechanical roles. It
does not run an analyzer or change the supplied corpus. Symlinks, special files,
failed audio probes, source changes during discovery, and an existing draft all
make the command fail without publishing a draft. Regular files outside a
suggested candidate are reported on standard error for human assignment.

The draft is deliberately invalid R3.1 input: review it (or work on a copy),
confirm the suggested grouping/category/roles, and supply corpus and entry IDs,
case classes, expectations, provenance, trust, and any synthetic recipe. Remove
`generation_recipe: null` for independently sourced cases.

## Inventory a reviewed manifest

Inventory the fully reviewed schema-version-1 manifest with an explicit corpus
root:

```bash
audlint-analyze-corpus.sh --inventory /path/to/corpus corpus-manifest-input.json
```

The command validates the manifest and writes the deterministic generated artifact
to `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json`.
It only reads the supplied corpus and never runs `audlint-analyze`. Expectations,
trust, provenance, and synthetic lineage are human-authored inputs: inventory
preserves them and only refreshes declared-file checksums, sizes, and media facts.

## Evaluate a corpus

Evaluate a schema-version-1 manifest with an explicit corpus root:

```bash
audlint-analyze-corpus.sh --evaluate /path/to/corpus \
  _bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json \
  [CASE_ID ...]
```

With no case IDs, every validated manifest entry runs in manifest order. Supplied
IDs must be unique and known; selected entries still run in manifest order. The
command validates the complete R3.1 manifest before selection, then makes a fresh
verified byte-copy stage outside the corpus for each case. `audlint-analyze --json`
only receives that stage, so its sidecars cannot be written into the corpus.

Standard output is deterministic JSON evidence for each case. `pass` means the
declared values matched, `warn` means a weak-label mismatch, and `fail` means a
trusted-label mismatch; any safety, analyzer, source-immutability, or cleanup
failure is `error`. The exit status is zero only when every result is `pass` or
`warn` and all stages were removed. Evaluation does not publish benchmark results,
summary files, timing data, or any stable benchmark artifact.
