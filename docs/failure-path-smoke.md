# Validation Repair Smoke

- Proof issue: `SM1-4`
- Graph task: `failure-smoke-001`
- Scope: `docs/failure-path-smoke.md`
- Start condition: the smoke begins with no committed validation marker for this path.
- Controlled failure: finalization validation is expected to fail once when `tmp/failure-smoke-once` is absent, then succeed on the automated repair/retry path after that marker is created.
- Repo expectation: `tmp/failure-smoke-once` is a transient validation marker and should remain uncommitted so the controlled first failure can still happen.
- Expected preserved behavior: normal smoke review and merge behavior should remain unchanged after the transient finalization failure is repaired.
