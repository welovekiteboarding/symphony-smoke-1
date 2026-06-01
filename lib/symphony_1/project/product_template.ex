defmodule Symphony1.Project.ProductTemplate do
  @moduledoc false

  alias Symphony1.Project.ProofIssue

  @spec files(map()) :: [{String.t(), String.t()}]
  def files(assigns) do
    [
      {"README.md", readme(assigns)},
      {"AGENTS.md", agents(assigns)},
      {".gitignore", gitignore()},
      {"config/symphony_setup.json", setup_intent(assigns)},
      {"priv/workflows/WORKFLOW.md", workflow(assigns)},
      {"planning/graph.json", assigns.graph_json}
    ]
  end

  defp readme(assigns) do
    """
    # #{assigns.project_name}

    This is a clean product repository controlled by Symphony.

    The application source should be created by graph-driven Codex work, not by copying the Symphony runtime into this repo.
    """
  end

  defp agents(_assigns) do
    """
    # AGENTS.md

    This is a product repository controlled by Symphony.

    Read first:

    1. `README.md`
    2. `planning/graph.json`
    3. `priv/workflows/WORKFLOW.md`

    Follow the graph task acceptance criteria, scope, and validation commands exactly.
    """
  end

  defp setup_intent(assigns) do
    Jason.encode!(
      %{
        project: %{
          name: assigns.project_name,
          type: "product"
        },
        github: %{
          repo: assigns.github_repo
        },
        linear: %{
          team_key: assigns.linear_team_key,
          team_name: assigns.linear_team_name,
          workflow_states: [
            "Todo",
            "In Progress",
            "Finalizing",
            "Human Review",
            "Rework",
            "Merging",
            "Done"
          ]
        },
        env: %{
          required: ["LINEAR_API_KEY"]
        },
        proof_issue: %{
          state: "Todo",
          title: ProofIssue.title(),
          description: ProofIssue.description()
        }
      },
      pretty: true
    )
  end

  defp workflow(assigns) do
    """
    ---
    tracker:
      kind: linear
    workspace:
      root: ./tmp/workspaces
    agent:
      max_concurrent_agents: 1
    codex:
      command: codex app-server
      turn_timeout_ms: 1200000
      task_timeout_ms: 1200000
    ---

    You are working on a Linear issue for #{assigns.project_name}.
    This is a clean product repository. Build only what the issue and graph task ask for.
    Relative workspace roots are resolved under Symphony's sterile temp workspace base, not under this product repo.
    """
  end

  defp gitignore do
    """
    /tmp/
    /node_modules/
    /dist/
    /coverage/
    /.symphony/
    .DS_Store
    """
  end
end
