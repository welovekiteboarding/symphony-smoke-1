defmodule Symphony1.Project.Template do
  alias Symphony1.Project.ProofIssue

  @spec files(map()) :: [{String.t(), String.t()}]
  def files(assigns) do
    [
      {"README.md", readme(assigns)},
      {"AGENTS.md", agents(assigns)},
      {".gitignore", gitignore()},
      {"config/symphony_setup.json", setup_intent(assigns)},
      {"docs/status.md", status(assigns)},
      {"docs/architecture.md", architecture(assigns)},
      {"docs/recovery-cleanup-policy.md", recovery_policy(assigns)},
      {"docs/linear-setup.md", linear_setup(assigns)},
      {"priv/workflows/WORKFLOW.example.md", workflow(assigns)},
      {"priv/workflows/WORKFLOW.md", workflow(assigns)},
      {".env.example", env_example(assigns)},
      {"lib/#{assigns.module_path}.ex", source_placeholder(assigns)},
      {"test/test_helper.exs", test_helper()},
      {"test/#{assigns.module_path}_test.exs", test_placeholder(assigns)}
    ]
  end

  defp readme(assigns) do
    """
    # #{assigns.project_name}

    `#{assigns.project_name}` is scaffolded from the Symphony harness shape.

    ## Control Surface

    - Linear team key: `#{assigns.linear_team_key}`
    - GitHub repo: `#{assigns.github_repo}`

    ## Workflow

    - `Todo`
    - `In Progress`
    - `Human Review`
    - `Rework`
    - `Merging`
    - `Done`
    """
  end

  defp agents(assigns) do
    """
    # AGENTS.md

    This repo embeds the Symphony harness for `#{assigns.project_name}`.

    Read first:

    1. `README.md`
    2. `docs/status.md`
    3. `docs/architecture.md`
    4. `docs/recovery-cleanup-policy.md`
    5. `priv/workflows/WORKFLOW.md`
    """
  end

  defp status(assigns) do
    """
    # #{assigns.project_name} Status

    ## Goal

    Build `#{assigns.project_name}` through the Symphony Linear -> Codex -> GitHub loop.
    """
  end

  defp setup_intent(assigns) do
    Jason.encode!(
      %{
        project: %{
          name: assigns.project_name
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

  defp architecture(assigns) do
    """
    # #{assigns.project_name} Architecture

    This repo embeds the Symphony harness shape for `#{assigns.project_name}`.
    """
  end

  defp recovery_policy(assigns) do
    """
    # #{assigns.project_name} Recovery And Cleanup Policy

    Failed claimed issues should move from `In Progress` to `Rework` before PR creation.
    """
  end

  defp linear_setup(assigns) do
    proof_description = indent(ProofIssue.description(), "      ")

    """
    # Linear Setup For #{assigns.project_name}

    ## Team

    - team name: `#{assigns.linear_team_name}`
    - team key: `#{assigns.linear_team_key}`
    - GitHub repo: `#{assigns.github_repo}`

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
    - title: `#{ProofIssue.title()}`
    - description:

    #{proof_description}

    ## Manual Notes

    - `mix symphony.setup` will create the first proof issue through the Linear API after team and workflow bootstrap succeeds
    - GitHub repo creation can be automated by `mix symphony.scaffold ... --github`
    - run one queue cycle with `mix symphony.run --once`
    - run the foreground queue with `mix symphony.run`
    """
  end

  defp indent(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
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
    Relative workspace roots are resolved under Symphony's sterile temp workspace base, not under this repo.
    """
  end

  defp env_example(_assigns) do
    """
    LINEAR_API_KEY=
    GITHUB_OWNER=
    GITHUB_REPO=
    """
  end

  defp gitignore do
    """
    /_build/
    /deps/
    /cover/
    /.symphony/
    erl_crash.dump
    .DS_Store
    """
  end

  defp source_placeholder(assigns) do
    """
    defmodule #{assigns.module_name} do
      def hello do
        :world
      end
    end
    """
  end

  defp test_placeholder(assigns) do
    """
    defmodule #{assigns.module_name}Test do
      use ExUnit.Case

      test "hello/0 returns :world" do
        assert #{assigns.module_name}.hello() == :world
      end
    end
    """
  end

  defp test_helper do
    """
    ExUnit.start()
    """
  end
end
