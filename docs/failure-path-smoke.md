# Validation Repair Smoke

- Proof issue: `SM1-4`
- Graph task: `failure-smoke-001`
- Scope: `docs/failure-path-smoke.md`
- Start condition: the smoke begins with no committed validation marker for this path, so the first finalization attempt can exercise the repair flow.
- Controlled failure: current finalization validation is expected to fail once when `/tmp/symphony-smoke-failure-path-smoke-once` is absent, then succeed on the automated repair/retry path after that marker is created.
- Repo expectation: the one-shot marker is transient and should remain uncommitted so the controlled first failure can still happen without changing product code or normal review flow.
- Expected preserved behavior: normal smoke review and merge behavior should remain unchanged after the transient finalization failure is repaired.
