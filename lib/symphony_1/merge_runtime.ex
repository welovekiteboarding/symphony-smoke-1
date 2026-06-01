defmodule Symphony1.MergeRuntime do
  alias Symphony1.Core.{GitHub, Linear, RunCoordinator, Workspace}
  alias Symphony1.Core.Policy
  alias Symphony1.Observability.Recorder
  alias Symphony1.Planning.Graph
  alias Symphony1.Project.SetupIntent
  alias Symphony1.Review
  alias Symphony1.RuntimeConfig
  alias Symphony1.WorkspaceRoot

  @setup_intent_path "config/symphony_setup.json"
  @graph_path "planning/graph.json"
  @workflow_path "priv/workflows/WORKFLOW.md"

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    graph_path = resolve_graph_path(cwd, Keyword.get(opts, :graph_path, @graph_path))

    with {:ok, merge_attrs} <- build_merge_attrs(cwd) do
      if Keyword.get(opts, :once, false) do
        merge_once(merge_attrs, graph_path, opts)
      else
        interval_ms = Keyword.get(opts, :interval_ms, 1_000)
        app_starter = Keyword.get(opts, :app_starter, &Application.ensure_all_started/1)

        Application.put_env(:symphony_1, :merge_runtime, %{
          enabled: true,
          interval_ms: interval_ms,
          merge_attrs: merge_attrs
        })

        {:ok, _apps} = app_starter.(:symphony_1)
        {:ok, %{merge_attrs: merge_attrs}}
      end
    end
  end

  @spec build_merge_attrs(String.t()) :: {:ok, map()} | {:error, term()}
  def build_merge_attrs(cwd \\ File.cwd!()) do
    workflow = workflow_config(cwd)

    with {:ok, intent} <- SetupIntent.load(Path.join(cwd, @setup_intent_path)) do
      team_key = get_in(intent, ["linear", "team_key"])

      with {:ok, linear_config} <- RuntimeConfig.linear_config(team_key) do
        {:ok,
         %{
           linear_config: linear_config,
           merge_strategy: workflow_merge_strategy(workflow),
           repo: get_in(intent, ["github", "repo"]),
           workspace_root: workspace_root(cwd, intent, workflow),
           workspace: cwd
         }}
      end
    end
  end

  defp merge_once(merge_attrs, graph_path, opts) do
    linear_poller =
      Keyword.get(
        opts,
        :linear_poller,
        fn config -> Linear.poll_issue_in_state(config, "Human Review") end
      )

    github_resolver =
      Keyword.get(
        opts,
        :github_resolver,
        fn attrs -> GitHub.find_pull_request_by_branch(attrs) end
      )

    merge_runner = Keyword.get(opts, :merge_runner, &RunCoordinator.merge_review/2)
    github_runner = Keyword.get(opts, :github_runner, &System.cmd/3)
    approval_reader = Keyword.get(opts, :approval_reader, &Review.read_artifact/2)
    base_refresher = Keyword.get(opts, :base_refresher, &GitHub.refresh_base_branch/1)

    case linear_poller.(merge_attrs.linear_config) do
      {:ok, issue} ->
        branch = "issue-" <> String.downcase(issue.identifier)
        issue_workspace = Workspace.path_for_issue(merge_attrs.workspace_root, issue.identifier)
        graph_task_id = graph_task_id_for_issue(issue.identifier, graph_path)

        case github_resolver.(%{
               branch: branch,
               repo: merge_attrs.repo,
               workspace: merge_attrs.workspace,
               cwd: merge_attrs.workspace
             }) do
          {:ok, pull_request} ->
            case merge_approval_status(approval_reader, merge_attrs.workspace, issue.identifier) do
              {:ok, :approved} ->
                with :ok <-
                       record_merge_event(
                         merge_attrs.workspace,
                         issue,
                         "merge_runtime_dispatched",
                         pull_request,
                         issue_workspace,
                         graph_task_id
                       ),
                     {:ok, result} <-
                       merge_runner.(
                         %{
                           graph_task_id: graph_task_id,
                           issue: issue,
                           linear_config: merge_attrs.linear_config,
                           merge_strategy: merge_attrs.merge_strategy,
                           observability_root: merge_attrs.workspace,
                           pull_request: pull_request,
                           workspace: issue_workspace
                         },
                         github_runner
                       ),
                     :ok <-
                       record_merge_event(
                         merge_attrs.workspace,
                         issue,
                         "merge_runtime_completed",
                         pull_request,
                         issue_workspace,
                         graph_task_id
                       ) do
                  base_refresh =
                    refresh_base_after_merge(base_refresher, %{
                      base_branch: pull_request.base_branch,
                      cwd: merge_attrs.workspace,
                      repo: merge_attrs.repo
                    })

                  {:ok,
                   %{
                     results: [result],
                     merge_attrs: merge_attrs,
                     base_refresh: base_refresh,
                     report:
                       merge_success_report(
                         issue.identifier,
                         result.issue.state,
                         pull_request.url,
                         base_refresh
                       )
                   }}
                else
                  {:error, reason} -> {:error, reason}
                end

              {:ok, :missing} ->
                {:ok,
                 %{
                   results: [],
                   merge_attrs: merge_attrs,
                   report: skipped_report(issue.identifier, "no approved review artifact was found")
                 }}

              {:ok, :not_approved} ->
                {:ok,
                 %{
                   results: [],
                   merge_attrs: merge_attrs,
                   report: skipped_report(issue.identifier, "review outcome was not approved")
                 }}

              {:error, reason} ->
                {:ok,
                 %{
                   results: [],
                   merge_attrs: merge_attrs,
                   report: merge_failure_report(issue.identifier, reason)
                 }}
            end

          :none ->
            {:ok,
             %{
               results: [],
               merge_attrs: merge_attrs,
               report: merge_failure_report(issue.identifier, {:pull_request_not_found, branch})
             }}

          {:error, reason} ->
            {:error, reason}
        end

      :none ->
        {:ok, %{results: [], merge_attrs: merge_attrs, report: no_work_report()}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_root(repo_root, intent, workflow) do
    WorkspaceRoot.resolve(repo_root, workflow, intent)
  end

  defp workflow_config(repo_root) do
    workflow_path = Path.join(repo_root, @workflow_path)

    if File.exists?(workflow_path) do
      case Policy.load_workflow_config(workflow_path) do
        {:ok, workflow} -> workflow
        {:error, _reason} -> nil
      end
    else
      nil
    end
  end

  defp merge_approval_status(approval_reader, repo_root, issue_identifier) do
    case approval_reader.(repo_root, issue_identifier) do
      {:ok, %{"outcome" => "approved"}} -> {:ok, :approved}
      {:ok, %{outcome: "approved"}} -> {:ok, :approved}
      :missing -> {:ok, :missing}
      {:ok, _artifact} -> {:ok, :not_approved}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refresh_base_after_merge(base_refresher, attrs) do
    case base_refresher.(attrs) do
      :ok -> :ok
      {:error, reason} -> {:warning, reason}
    end
  end

  defp workflow_merge_strategy(nil), do: "merge"

  defp workflow_merge_strategy(workflow) do
    get_in(workflow, ["github", "merge_strategy"]) || "merge"
  end

  defp record_merge_event(cwd, issue, event, pull_request, workspace, graph_task_id) do
    Recorder.record(cwd, event,
      issue_identifier: issue.identifier,
      graph_task_id: graph_task_id,
      phase: "merge",
      details: %{
        workspace_path: workspace,
        branch: pull_request.branch,
        base_branch: pull_request.base_branch,
        pull_request_url: pull_request.url
      }
    )
  end

  defp resolve_graph_path(cwd, graph_path) do
    if Path.type(graph_path) == :absolute do
      graph_path
    else
      Path.join(cwd, graph_path)
    end
  end

  defp graph_task_id_for_issue(issue_identifier, graph_path) do
    with {:ok, graph} <- Graph.load(graph_path),
         {:ok, task} <- Graph.find_task_by_issue_identifier(graph, issue_identifier) do
      task.id
    else
      _error -> nil
    end
  end

  defp merge_success_report(issue_identifier, issue_state, pull_request_url, base_refresh) do
    %{
      status: :success,
      issue_identifier: issue_identifier,
      pull_request_url: pull_request_url,
      summary: "Merge completed for #{issue_identifier} -> #{issue_state} (#{pull_request_url})."
    }
    |> maybe_add_base_refresh_warning(base_refresh)
  end

  defp skipped_report(issue_identifier, reason) do
    %{
      status: :skipped,
      issue_identifier: issue_identifier,
      summary: "Merge skipped for #{issue_identifier}: #{reason}."
    }
  end

  defp merge_failure_report(issue_identifier, reason) do
    %{
      status: :failure,
      issue_identifier: issue_identifier,
      reason: reason,
      summary: merge_failure_summary(issue_identifier, reason)
    }
  end

  defp merge_failure_summary(issue_identifier, {:invalid_artifact, reason}) do
    "Merge failed for #{issue_identifier}: review artifact was invalid (#{inspect({:invalid_artifact, reason})})."
  end

  defp merge_failure_summary(issue_identifier, {:pull_request_not_found, branch}) do
    "Merge failed for #{issue_identifier}: pull request was not found for branch #{branch}."
  end

  defp merge_failure_summary(issue_identifier, {:artifact_read_failed, reason}) do
    "Merge failed for #{issue_identifier}: review artifact could not be read (#{inspect({:artifact_read_failed, reason})})."
  end

  defp merge_failure_summary(issue_identifier, reason) do
    "Merge failed for #{issue_identifier}: review artifact check failed (#{inspect(reason)})."
  end

  defp no_work_report do
    %{
      status: :no_work,
      summary: "Merge poll found no issues in Human Review."
    }
  end

  defp maybe_add_base_refresh_warning(report, {:warning, reason}) do
    warning = %{
      code: :base_refresh_failed,
      reason: reason,
      summary: "Local base refresh failed after merge: #{inspect(reason)}."
    }

    Map.update(report, :warnings, [warning], fn warnings ->
      if Enum.any?(warnings, &(&1 == warning)), do: warnings, else: warnings ++ [warning]
    end)
  end

  defp maybe_add_base_refresh_warning(report, _base_refresh), do: report
end
