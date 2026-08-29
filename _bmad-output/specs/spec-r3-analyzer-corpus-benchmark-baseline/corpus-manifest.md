# Corpus Manifest Contract

## Ownership and root

The committed manifest is a versioned BMAD artifact. It never embeds a machine-specific corpus root; the caller supplies the root at runtime. Every stored path is POSIX-style, relative to that root, normalized without `.` or `..`, and resolves inside the root.

`/Volumes/Music/Tests` is the approved runtime root for the first baseline. The manifest describes it but is never written there.

The first inventory preserves the existing top-level meaning: `real/` contains genuine profile families, `fake/` contains labeled MP3/AAC/Opus upscale cases, and `edge_cases/` contains low-pass mastering, noisy live, and vinyl-rip cases.

## Contract document and generated manifest

This file, `corpus-manifest.md`, defines the manifest contract; it is not the runtime corpus inventory. The generated inventory has the stable repository-relative path `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json`.

The generated manifest is one UTF-8 JSON object using the fields below. It uses two-space indentation, lexicographically sorted object keys, LF line endings, and one final newline. Array order is preserved, including the deterministic `entries` order. The runner records the SHA-256 of these exact bytes as the corpus-contract identity.

## Top-level fields

| Field | Requirement |
| --- | --- |
| `schema_version` | Required integer; first supported value is `1`. |
| `corpus_id` | Required stable identifier for this corpus. |
| `corpus_revision` | Required immutable revision label for the inventoried content. |
| `generated_at_utc` | Required RFC 3339 inventory timestamp. |
| `entries` | Required ordered array; order is the deterministic runner and report order. |

The manifest's SHA-256 is the corpus-contract identity recorded by every result artifact.

## Entry fields

| Field | Requirement |
| --- | --- |
| `id` | Required stable unique case ID; changing a path does not silently change identity. |
| `album_path` | Required root-relative album or case directory. Absolute paths and traversal are invalid. |
| `category` | Required: `real`, `fake`, or `edge_case`. |
| `case_class` | Required stable coverage label, such as `genuine-48000-24`, `fake-mp3-192-96000`, `dsd-family`, or `cue-wavpack-large`. |
| `files` | Required non-empty ordered input-file inventory. |
| `expected_source_profile` | Required independently established source profile. PCM uses canonical `SR_HZ/BITS`; DSD-family cases use an explicit DSD family label and retain native probe facts in `files`. |
| `expected_target_profile` | Required analyzer target in canonical `SR_HZ/BITS`. This replaces the current runner's ambiguous `expected_profile` meaning. |
| `expected_decision` | Required analyzer decision class, including `keep_source`, `cap_highres_ceiling`, or `downgrade_fake_upscale`. |
| `expected_fake_upscale` | Required boolean. |
| `expected_analysis_mode` | Optional expectation used only when the mode itself is part of the case. |
| `trust` | Required: `trusted` or `weak`. Unknown values are invalid, not silently normalized. |
| `provenance` | Required object establishing how the expectations were obtained and reviewed. |
| `generation_recipe` | Required for synthetic derivatives; absent for independently sourced media. |

Each `files` item records `path`, `role`, `sha256`, and `bytes`. Audio items also record container, codec, sample rate, bit depth when meaningful, channels, and duration. CUE sheets and other structural inputs retain their checksum and role even when audio probe fields do not apply.

## Provenance and trust

`provenance` records a basis, source reference or recipe lineage, rationale, reviewer identity, and UTC review date.

Expected analyzer truth is human-owned. Automated inventory may enumerate files, compute checksums and sizes, and collect objective probe facts such as container, codec, sample rate, bit depth, channels, and duration. It must not populate, change, validate by agreement with, or promote `expected_source_profile`, `expected_target_profile`, `expected_decision`, `expected_fake_upscale`, `expected_analysis_mode`, provenance, or trust from Audlint output.

A case is `trusted` only when all apply:

- Its source profile or synthetic lineage is established independently of the current Audlint result.
- A named human reviewer has explicitly reviewed the provenance and every expected source profile, target profile, decision, and fake-upscale value, plus expected analysis mode when present.
- Every declared input is checksum-pinned.
- A synthetic case names the trusted source checksum, exact `audlint-dataset.sh` invocation parameters, and relevant encoder/tool versions.

A case is `weak` when its expectation is retained from incomplete or historical evidence, inherited from a library/database label, or based on previous Audlint output. Such evidence may remain useful as a weak expectation but cannot establish truth. Weak is the default human review outcome, never an implicit parser fallback. Promotion from `weak` to `trusted` is an explicit human-reviewed manifest change; a passing analyzer run cannot promote it.

If an entry is declared or requested as `trusted` without the required reviewed provenance or expected values, manifest validation stops with an error. Inventory and evaluation must not invent the missing values, copy current Audlint output into them, silently downgrade the entry, or publish a trusted baseline from incomplete truth.

## Required coverage

| Family | Minimum represented classes |
| --- | --- |
| Genuine PCM | 44.1 kHz and 48 kHz families, including 44.1/16, 44.1/24, 48/24, 96/24, and 192/24. |
| Fake upscale | MP3, AAC, and Opus lineage at multiple source bitrates, with 48, 96, and 192 kHz fake target families represented. |
| Genuine high resolution | Sparse-content high-resolution cases that must not be downgraded solely for limited ultrasonic energy. |
| Edge cases | Low-pass mastering, noisy live recordings, and vinyl rips. |
| Format/layout | DSD-family sources and large CUE/WavPack cases. |
| Presentation traps | Misleading spectrogram exports remain labeled evidence, not analyzer truth. |

Coverage validation reports missing classes; it does not fabricate cases or labels.

## Inventory and synthetic verification

Inventory is read-only: resolve the supplied root, enumerate inputs, compute objective metadata and SHA-256 values, merge only human-supplied expectations and provenance, validate coverage and trust requirements, and write the generated JSON manifest only at its declared BMAD output path.

`audlint-dataset.sh` reproduces declared derivatives into a new temporary destination. Reproduction passes only when the generated files match the manifest's declared lineage, media metadata, and checksums. It never targets the approved corpus or the repository.
