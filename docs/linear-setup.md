# Linear Setup For symphony-smoke-1

## Team

- team name: `SymphonySmoke1`
- team key: `SM1`
- GitHub repo: `welovekiteboarding/symphony-smoke-1`

## Workflow States

- `Todo`
- `In Progress`
- `Human Review`
- `Rework`
- `Merging`
- `Done`

## Environment Checklist

- set `LINEAR_API_KEY`
- confirm GitHub auth for `gh`
- confirm Codex is installed and available on the path

## Create The First Proof Issue

Create the first proof issue in Linear with:

- state: `Todo`
- title: `Create deterministic live-proof artifact`
- description:

      Add a new file at docs/live-proof-setup-run-merge.md. Record only facts visible before Symphony finalization commits this issue.
      
      # Live Proof Setup Run Merge
      
      Required facts:
      - Proof issue: <issue identifier>
      - Branch: <current git branch>
      - Base HEAD: <current git HEAD SHA and subject before this proof file is committed>
      - File evidence: <state that docs/live-proof-setup-run-merge.md was created for this proof issue>
      - Current scope: <state only what this issue proves before review or merge>
      
      Rules:
      - Use only facts visible in the issue prompt, workspace files, current branch name, or local git history before finalization.
      - Do not record or claim the final issue commit SHA; Symphony creates that commit after the worker returns.
      - Do not claim a PR, review result, merge result, or Linear workflow state unless that fact is visible in the workspace before finalization.
      - Markdown bullet marker style is not significant; '-' and '*' bullets are both acceptable when the required facts are present.

## Manual Notes

- `mix symphony.setup` will create the first proof issue through the Linear API after team and workflow bootstrap succeeds
- GitHub repo creation can be automated by `mix symphony.scaffold ... --github`
- run one queue cycle with `mix symphony.run --once`
- run the foreground queue with `mix symphony.run`
