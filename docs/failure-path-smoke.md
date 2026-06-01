# Validation Repair Smoke

- Proof issue: `SM1-4`
- Graph task: `failure-smoke-001`
- Scope: `docs/failure-path-smoke.md`
- Controlled failure: finalization validation is expected to fail once when `tmp/failure-smoke-once` is absent, then succeed on the automated repair/retry path after that marker is created.
- Expected preserved behavior: normal smoke review and merge behavior should remain unchanged after the transient finalization failure is repaired.
