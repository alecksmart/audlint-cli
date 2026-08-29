---
id: SPEC-r3-5-synthetic-verification-final-baseline-publication
companions: []
sources:
  - ../spec-r3-analyzer-corpus-benchmark-baseline/SPEC.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/corpus-manifest.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/benchmark-protocol.md
  - ../spec-r3-analyzer-corpus-benchmark-baseline/brownfield.md
  - ../spec-r3-1-corpus-manifest-safe-inventory/SPEC.md
  - ../spec-r3-2-immutable-staging-accuracy-verdict/SPEC.md
  - ../spec-r3-3-analyzer-work-instrumentation/SPEC.md
  - ../spec-r3-4-cold-warm-serial-benchmark-execution/SPEC.md
  - ../spec-r3-4-cold-warm-serial-benchmark-execution/benchmark-results-schema.md
  - ../../../docs/architecture/OVERVIEW.md
---

> **Canonical contract.** This SPEC is the complete, preservation-validated contract for what R3.5 builds, tests, and validates. Source documents are listed only for traceability; this child contract absorbs every requirement needed by a fresh-context implementation.

# R3.5 Synthetic Verification and Final Baseline Publication

## Why

R3.1 through R3.4 define the corpus identity, safe accuracy evidence, analyzer work counters, and serial cold/warm measurements, but R3 is not complete until declared synthetic lineage is independently reproduced and those artifacts are checked and published as one readable baseline. Maintainers need a finalization gate that exposes failures and limitations without allowing successful generation or analysis to strengthen weak truth, conceal upstream contradictions, or write generated media into the approved corpus or repository.

## Capabilities

- **CAP-1 — Validated final evidence intake**
  - **intent:** Maintainers can finalize only a complete R3.1 manifest and R3.4 benchmark result whose embedded R3.2 verdicts and R3.3 work evidence retain their authoritative meanings.
  - **success:** Full upstream validation rejects missing, malformed, unsupported, internally contradictory, misreferenced, or aggregate-inconsistent evidence before reproduction or publication, while a well-formed recorded benchmark failure remains visible evidence rather than being repaired or discarded.

- **CAP-2 — Safe synthetic reproduction**
  - **intent:** Maintainers can reproduce every declared synthetic lineage without exposing approved corpus or repository paths to generated-media writes.
  - **success:** Every manifest entry with `generation_recipe` is covered by a declared `audlint-dataset.sh` invocation that reads a verified temporary copy of its trusted source and writes only to a fresh temporary destination outside the corpus and repository, with serial execution, complete cleanup, and unchanged source evidence.

- **CAP-3 — Synthetic lineage and output verdict**
  - **intent:** Maintainers can prove that each synthetic case came from the declared trusted source and generation toolchain independently of Audlint's current decision.
  - **success:** Reproduction passes only when source checksum, normalized recipe, tool identity and versions, declared output set, checksums, byte sizes, and expected objective media metadata all match; any lineage, recipe, generation, checksum, or metadata mismatch fails verification and no result changes an entry's expectations, provenance, or trust.

- **CAP-4 — Concise final baseline summary**
  - **intent:** Maintainers can understand the analyzer baseline without reading or duplicating every raw machine record.
  - **success:** The exact parent-defined `baseline-summary.md` separately reports synthetic verification, trusted passes and failures, weak warnings, execution errors, exclusions, cold/warm runtime, repeated probe/decode work, fallback costs, environment and toolchain identity, limitations, and traceable case, sample, and artifact references.

- **CAP-5 — Cross-artifact publication gate**
  - **intent:** Maintainers can tell that the manifest, benchmark result, synthetic verification, repository revision, and generated summary describe one baseline.
  - **success:** One final consistency check proves the identities and references below agree, then atomically publishes the summary; any inconsistency or publication failure returns nonzero evidence and leaves all previously published stable artifacts unchanged.

## Constraints

- R3.5 consumes, without rewriting, `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/corpus-manifest.json` and `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/benchmark-results.json`. It publishes only `_bmad-output/benchmarks/r3-analyzer-corpus-benchmark-baseline/baseline-summary.md`; the three parent-defined files remain the complete stable runtime baseline and no fourth stable artifact is added.
- Run the complete R3.1 manifest validator and R3.4 result-schema validator before synthetic generation. R3.2 accuracy evidence and R3.3 counters are consumed only through their unchanged R3.4 sample fields; R3.5 does not coerce, rename, recompute under new semantics, or infer missing upstream evidence.
- Recompute SHA-256 from the exact manifest bytes and require it to equal the benchmark manifest identity. `corpus_id`, `corpus_revision`, case ID, trust, category, case class, root-relative path, sample and exclusion references, planned order, status counts, and R3.4 aggregates must agree with the manifest and raw samples. Missing or contradictory values stop finalization; they are never filled from another artifact.
- A valid benchmark may contain trusted `fail`, weak `warn`, execution `error`, and converter `excluded` records. After the synthetic and consistency gates pass, publish those findings faithfully and preserve the R3.2/R3.4 nonzero verdict; do not misclassify a recorded failing baseline as an inconsistent artifact.
- Select every manifest entry containing `generation_recipe`, including both `trusted` and `weak` entries, in manifest order. Equivalent normalized recipes may run once only when the implementation still verifies every associated entry and the complete union of outputs declared for that invocation.
- Before invoking generation, resolve the recipe's trusted source identity to manifest-declared regular-file inputs and verify their byte sizes and SHA-256 values. The recipe must identify `audlint-dataset.sh`, its exact invocation parameters and relevant environment settings, and the encoder or tool versions required by R3.1. Missing facts, an unexpected executable, changed parameters, or a current-versus-declared tool identity mismatch is a lineage failure, not a reason to update the recipe.
- Byte-copy the trusted source inputs into a unique temporary source stage and verify them again. Resolve a separate fresh temporary output destination outside both the supplied corpus root and repository root. Do not use symlinks or hard links, and pass only these temporary media paths to `audlint-dataset.sh`.
- Synthetic verification is serial. Set `AUDLINT_DATASET_JOBS=1`, execute no generation commands concurrently, and otherwise preserve the declared recipe. R3.5 may route source and destination through stable temporary-path roles but may not alter generation semantics to make an old recipe pass.
- For each recipe invocation, the generated regular-file identities must equal its manifest-declared output set. Missing, extra, partial, symlinked, or undeclared output files are generation failures. Compare each accepted output with the manifest using the shared R3.1 objective-fact and profile rules: SHA-256, byte size, container, codec, sample rate, applicable bit depth, channels, and duration must match.
- Reproduction verifies lineage, not analyzer truth. It must not run Audlint to establish a checksum or expected value, edit the manifest, change provenance, or promote trust. A `weak` entry remains `weak` even when its generation and analyzer results both pass.
- Apply the R3.2 complete-subtree snapshot rules to every referenced corpus source boundary before and after temporary source staging. Capture verification evidence before cleanup and attempt cleanup on success and every failure path. A source mutation, destination escape, undeclared write, or cleanup failure blocks publication.
- Generate concise UTF-8 CommonMark with LF line endings and one final newline. Use distinct sections for: baseline identity and environment; synthetic verification; trusted accuracy results; weak warnings; execution errors; excluded cases; cold/warm runtime; repeated probe and decode work; expensive fallback classes; known limitations; and the machine-evidence index. State explicitly when a population is empty.
- Summarize accuracy by manifest case identity from analyzer `accuracy_evidence`. Keep trusted passes and failures separate from weak warnings; keep execution errors separate regardless of trust; and never fold exclusions into passes, errors, or elapsed aggregates.
- Present only verified R3.4 runtime aggregates and cite the supporting sample IDs. Describe repeated work from structured `metadata_probe_count` and `decode_operation_count` evidence across comparable cold/warm pairs. Describe fallback cost from the existing selected-strategy, fast-to-exact, and segment-to-full groups. Never infer cache use or work from elapsed time; when evidence lacks a valid comparator, state that the finding is inconclusive.
- Report the R3.4 environment and toolchain identity exactly, including serial settings, iteration count, application-cache observations, repository full commit and recorded dirty state, and the fixed limitation that operating-system page cache is uncontrolled. Require the live full `HEAD` at finalization to equal the benchmark commit; because dirty content is not reconstructible from a boolean, report a dirty benchmark as a reproducibility limitation rather than claiming a clean source state.
- The summary identifies the exact manifest SHA-256, `corpus_id`, `corpus_revision`, benchmark-results SHA-256, benchmark timestamp, repository commit and dirty marker, and every cited manifest case or sample ID. Link to the sibling JSON files and keep raw samples, diagnostics, full expected/actual records, and environment dumps in machine evidence rather than duplicating them into Markdown.
- Build the summary through a temporary candidate and atomically replace the stable path only after schema, reference, aggregate, identity, synthetic, source-safety, and cleanup checks pass. Any failure in those gates or in publication returns nonzero machine-readable diagnostics and leaves an existing summary and both JSON files untouched.
- A successfully published summary returns the unchanged upstream verdict: zero only when R3.2/R3.4 allow it and synthetic verification and finalization pass; nonzero for trusted failures or execution errors even though their valid summary is published. Synthetic, consistency, safety, cleanup, or publication failures do not publish a new summary.
- Keep `bin/audlint-analyze-corpus.sh` a thin operator boundary. Reuse R3.1 validation and probing, R3.2 staging and snapshots, and R3.4 result validation from `lib/py/audlint_analyze_corpus.py` or focused shared Python modules. `bin/audlint-dataset.sh` remains the declared generator; do not duplicate its generation policy in the finalizer.
- Automated verification uses repository-owned temporary manifests, media fixtures, tool stubs, temporary project roots, and injected repository, clock, and tool-version facts only. It must not access `/Volumes/Music/Tests`, a real music library, live SQLite database, mounted sync destination, backup target, or destructive audio, tag, artwork, or conversion workflow.
- Focused tests cover synthetic reproduction success and generator failure; trusted-source and output checksum mismatch; wrong recipe, executable, or tool-version lineage; output metadata mismatch; missing and extra outputs; temporary-only source and destination paths; source immutability; weak-trust preservation; cleanup after success and failure; all required summary sections and evidence links; deterministic rendering; valid failing-benchmark publication; atomic no-overwrite failure; and manifest, benchmark, repository, synthetic, and summary identity consistency.
- Completion requires `python3 -m unittest test.test_audlint_dataset_smoke test.test_audlint_analyze_corpus_smoke test.test_audlint_analyze_corpus_benchmark test.test_audlint_analyze_corpus_baseline test.test_audlint_value_smoke test.test_cue2flac_smoke test.test_any2flac_smoke test.test_dff2flac_smoke` and then `make check` to pass without external media access.
- Preserve Bash 5, Python portability across supported macOS/Linux hosts, canonical `SR_HZ/BITS` profiles, and `audlint-analyze` as the sole recode-decision authority.

## Non-goals

- Changing R3.1 manifest, inventory, coverage, provenance, trust, expected-value, generation-recipe, or canonical-serialization semantics.
- Changing R3.2 selection, staging, snapshots, accuracy verdicts, evidence, or cleanup semantics.
- Adding or changing R3.3 counters, counting rules, strategy, fallback, confidence, or decision evidence.
- Changing R3.4 applicability, cold/warm execution, timing, cache observation, converter safety, ordering, result schema, aggregation, or publication semantics.
- Optimizing analyzer, cache, probe, decode, generation, fallback, converter, or runtime behavior.
- Changing analyzer thresholds, decisions, modes, cache policy, worker models, or execution order.
- Adding parallel analysis, conversion, generation, or publication.
- Automatically publishing a release, merging to `main`, redistributing audio, or committing generated synthetic media.
- Implementing R3A, R4, R5, R6, or later roadmap work.

## Success signal

The focused command and `make check` prove with temporary fixtures that every declared synthetic recipe either reproduces output bytes and media facts matching the manifest entirely outside source and repository paths or blocks publication without weakening trust or overwriting prior artifacts. With explicit operator approval for the external corpus, one finalization run then exits with the preserved baseline verdict and leaves exactly the validated manifest, validated benchmark result, and identity-linked `baseline-summary.md` at the parent-defined paths; the summary and machine evidence name the same corpus revision, manifest hash, benchmark hash, repository commit, cases, samples, lineage, environment, and limitations.
