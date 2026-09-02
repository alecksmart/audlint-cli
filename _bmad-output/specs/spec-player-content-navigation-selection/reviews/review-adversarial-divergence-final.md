# Adversarial Divergence Final Confirmation

## Verdict

**PASS.** No remaining critical, high, or medium compliant-but-incompatible construction was found in the six closure areas.

- Protocol traffic now separates `EVENT(key|resize)` from correlated `EFFECT_UPDATE(progress|done)`, names `measure-checked`, `mutation`, `sync`, and `quit`, and fixes their v1 artifact roles.
- Compare-and-apply mismatch now returns authoritative membership, refreshes only frozen identities, retains the mismatch error, and exits on new or invalid identities.
- Busy input now drains ordinary bytes and partial sequences locally, coalesces resize, and forwards only resize and correlated effect updates.
- Base-less and otherwise width-variable clusters now render as exactly one `?` cell and are rejected from search input.
- Result producers and transitions now distinguish information, persistent body context, and accepted-effect failures.
- Every frame-producing request now carries fresh geometry, destination presence, and informational free bytes, fixing observation timing within the single request/paint cycle.

The synchronization contract also remains closed: accepted `w` rereads durable membership, performs complete shared preflight and final revalidation, takes no projection payload, proves identical manifests across projections, preserves zero-checked root deletion, and blocks unknown checked paths before transfer.
