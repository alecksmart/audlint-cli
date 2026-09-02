# Adversarial Divergence Closure Review

## Verdict

**One more tightening pass is required.** The revision closes the original ordering, scoped-delta, scroll resize, core Unicode, success/error lifetime, and synchronization-membership gaps. One protocol contradiction and two state-reconciliation gaps can still produce incompatible units; three narrower ambiguities remain.

## Critical

### 1. Protocol v1 assigns effect progress/completion to two different request shapes and cannot name initial sizing

**Compliant unit A:** It sends worker updates as `EFFECT_UPDATE(effect-id,effect-progress,...)` and `EFFECT_UPDATE(effect-id,effect-done,...)`, following AD-5.

**Compliant unit B:** It sends `EVENT(effect-progress,...)` and `EVENT(effect-done,...)`, following the Protocol v1 table, which lists both as event classes.

Both use a declared controller kind and an allowed class, but the model validators are incompatible. In addition, `STATE` may request only `mutation`, `sync`, or `quit`; there is no effect kind for the binding initial checked-set measurement. One implementation can size before `INIT`, while another invents a model-requested measurement effect, and only the latter can naturally render model-owned startup progress.

**Required correction:** Reserve `EVENT` for `key`, `resize`, and `destination`; reserve `EFFECT_UPDATE` for correlated `progress` and `done` classes. Add a named `measure-checked` effect (or explicitly bind pre-`INIT` sizing and waive model-owned progress) and give every effect intent/update a fixed versioned artifact schema.

## High

### 2. A failed compare-and-apply has no single reconciliation outcome

**Compliant unit A:** On expected-set mismatch, the controller performs the required fresh SQLite read, reports failure, and continues with the model's old membership because only a successful commit acknowledgement may change it.

**Compliant unit B:** It performs the same read and sends the authoritative checked set to the model as a non-commit refresh, updating membership before the next action.

Both commit nothing and perform the required read. A repeats the same failed precondition indefinitely; B changes model membership without a protocol kind or rule that distinguishes refresh from commit acknowledgement. If the fresh set contains a path outside the frozen union, B also conflicts with immutable inventory.

**Required correction:** Define one mismatch path. For example: refresh known frozen identities through a named authoritative-membership event; if the read introduces an identity outside the frozen union or cannot be validated, terminate Player Content and require fresh entry. State whether the mismatch error remains visible after a successful refresh.

### 3. The “every key is an event” rule conflicts with foreground input draining

**Compliant unit A:** During measurement or sync, it drains and discards ordinary bytes locally as AD-7 requires; only resize and the final effect update reach the model.

**Compliant unit B:** It parses every drained key and serializes a model request because AD-8 says every key first becomes one model event; the busy model returns unchanged frames.

Both prevent replay and effects, but B can starve progress/resize behind a paste-sized queue under the one-outstanding-request protocol, while A violates the literal event-loop rule.

**Required correction:** Exempt bytes drained during foreground work from key events. The controller should discard ordinary bytes and partial sequences locally, coalesce resize to the latest acknowledged geometry, and send only resize plus correlated effect updates while busy.

## Medium

### 4. Base-less grapheme clusters have no width/sanitization result

A cluster containing only assigned combining or format scalars is neither one of AD-4's listed unsupported classes nor a cluster with a printable base. One terminal-text implementation can assign width zero; another can emit a one-cell replacement to prevent attachment to the preceding cell. Both follow the written width branches, but their clipping and caret positions differ.

**Required correction:** State that any cluster without exactly one measurable printable base is rendered as one fixed one-cell replacement and is not accepted into search input.

### 5. Information-result producers remain unclassified

The transition table now converges for success and effect failure, but the spine does not classify bounded feedback for unsupported search input, malformed paste, movement at a boundary, empty inventory, or blocked unavailable additions. One unit can install these as `information`; another can treat some as persistent `error` or mode-local text. Both preserve the stated priority and clearing rules after choosing a class.

**Required correction:** Bind non-effect validation/no-op feedback to `information`, and reserve `error` for failed accepted mutations, measurement, protocol, or synchronization stages—or provide another complete producer classification.

### 6. Destination observation timing is not fixed within the request/paint cycle

**Compliant unit A:** It queries destination state before every user/resize request and includes it in that event payload.

**Compliant unit B:** It processes the triggering event, then queries destination state and sends a second `EVENT(destination)`; only the second returned frame is painted.

Both make every actual redraw fresh and model-derived, but they differ in request count, intermediate result transitions, and ordering against resize or effect completion.

**Required correction:** Bind destination presence as observation fields carried on every frame-producing `EVENT`/`EFFECT_UPDATE`, or bind the two-request sequence and prohibit painting the intermediate state.

## Verified closed

- AD-2 now fixes display/key separation, Unicode order keys, comparison domains, and the path-byte tie-break.
- AD-3 now fixes album/artist mutation scope, disjoint deltas, compare-and-apply, and rows outside scope.
- AD-7 now provides an acknowledged virtwin geometry helper and one scroll-region owner.
- AD-4 now owns grapheme tables and width policy without libc/package drift; only the base-less-cluster branch remains.
- AD-8 now defines the core semantic-frame loop and success/error transition taxonomy.
- AD-9 and AD-10 now require complete shared preflight, pre-rsync failure closure, projection-independent checked-set snapshots, identical manifests across projections, zero-checked deletion scope, and unknown-size transfer blocking. No remaining synchronization preflight/projection divergence was found.
