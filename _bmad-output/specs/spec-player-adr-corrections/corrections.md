# ADR Correction Contract

## ADR-0007: Track-only destination policy

- Keep canonical-extension track eligibility, hidden-path exclusion, source immutability, explicit transfer, root ownership, browser subtree ownership, and retryable non-atomic destination updates.
- Define an exact destination as equality of eligible paths, object types, and logical sizes. Do not imply independent byte equality.
- Require browser-owned destination subtrees to be validated, non-overlapping, and collision-free.
- Record that a canonical extension registry change requires player-transfer impact review because it changes destructive payload membership.
- Qualify retry convergence as applying to a later successful retry with unchanged valid inputs.
- Remove the obsolete statement that the follow-on contract has not been built.
- Remove display-only free-space policy from this ADR; its behavior remains unchanged and belongs to its owning product contract.

## ADR-0008: Snapshot transfer mechanism and equivalence

- Keep file-backed exact snapshots, one ordered merge-rule file, bounded rsync arguments, safe temporary artifacts, root versus subtree execution, `--delete-excluded`, `-r`, approved `--size-only`, flush, and postchecks.
- Make the title and stated scope honestly cover the approved concerns retained in this ADR. Correct it in place rather than create ADR-0009.
- State that `--size-only` intentionally treats equal-size source and destination tracks as unchanged; same-size content changes remain outside the accepted operating model.
- Replace broad source-stability claims with path, object-type, and logical-size snapshot stability.
- State that destination postchecks prove owned paths, object types, and logical sizes, not independent byte integrity.
- Describe AppleDouble as the observed result of requested metadata writes that recursive content copying avoids. Do not guarantee that no sidecar can arise from another tool or filesystem interaction.
- State that an empty completed snapshot compiles to the terminal exclusion needed for approved zero-selection deletion after full preflight.
- State that a multi-album browser failure may leave earlier requested subtrees changed; an unchanged retry rebuilds artifacts and reprocesses the request.
- State that artifacts left by an untrappable interruption carry no authority and are never reused.
- Retain rejected rsync alternatives only where pinned real-rsync evidence supports the claimed semantics.
- Condense exact helper sequencing and repeated implementation detail into durable invariants.

## Evidence and language

- Label pre-implementation observations as decision-baseline evidence and pin them to the relevant commit instead of calling replaced code current.
- Cite current implementation or focused tests separately when claiming the decision is implemented.
- Replace stale line references or anchor them to a commit where they remain historical evidence.
- Keep the accepted status and amendment history clear; do not rewrite history as though every clause existed at initial acceptance.
- Update `docs/decisions/README.md` only if ADR-0008's title or scope summary changes.

## Verification

- Compare every retained guarantee against current code, focused player tests, accepted player specs, and Git history.
- Confirm the diff changes only the permitted decision-ledger files.
- Resolve every local link and run `git diff --check` on the corrected ADR files.
- Do not run live-resource verification or modify runtime artifacts.
