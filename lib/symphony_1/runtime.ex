defmodule Symphony1.Runtime do
  require Logger

  alias Symphony1.Core.{Policy, QueueLauncher, QueueScheduler, RunCoordinator, Workspace}
  alias Symphony1.Planning.Graph
  alias Symphony1.Project.SetupIntent
  alias Symphony1.RuntimeConfig
  alias Symphony1.WorkspaceRoot

  @setup_intent_path "config/symphony_setup.json"
  @workflow_path "priv/workflows/WORKFLOW.md"
  @graph_path "planning/graph.json"
  @default_await_timeout_ms 600_000

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    with {:ok, run_attrs} <-
           build_run_attrs(
             Keyword.get(opts, :cwd, File.cwd!()),
             Keyword.get(opts, :graph_path, @graph_path)
           ),
         {:ok, workflow} <- Policy.load_workflow_config(run_attrs.workflow_path) do
      if Keyword.get(opts, :once, false) do
        launcher = Keyword.get(opts, :launcher, &QueueLauncher.launch/1)
        progress_reporter = Keyword.get(opts, :progress_reporter, fn _message -> :ok end)

        await_timeout_ms =
          Keyword.get(
            opts,
            :await_timeout_ms,
            get_in(workflow, ["codex", "task_timeout_ms"]) || @default_await_timeout_ms
          )

        run_attrs =
          run_attrs
          |> Map.put(:progress_reporter, progress_reporter)
          |> maybe_put_allowed_issue_identifiers(Keyword.get(opts, :allowed_issue_identifiers))

        queue_scheduler =
          QueueScheduler.new(
            max_concurrent_agents: get_in(workflow, ["agent", "max_concurrent_agents"]) || 1,
            launcher: launcher
          )

        Logger.info(
          "symphony.runtime: draining queue (once=true, team=#{run_attrs.linear_config.team_key})"
        )

        queue_scheduler = QueueScheduler.drain_once(queue_scheduler, run_attrs)
        active_count = map_size(queue_scheduler.active_runs)

        Logger.info(
          "symphony.runtime: waiting for #{active_count} active run(s) (timeout=#{await_timeout_ms}ms)"
        )

        case wait_for_active_runs(queue_scheduler, await_timeout_ms, run_attrs) do
          {:ok, results} ->
            Logger.info("symphony.runtime: queue drain complete (#{length(results)} result(s))")
            {:ok, %{queue_scheduler: queue_scheduler, results: results, run_attrs: run_attrs}}

          {:error, failures, results} ->
            Logger.warning("symphony.runtime: queue drain had #{length(failures)} failure(s)")
            {:error, {:issue_runs_failed, failures, results}}
        end
      else
        interval_ms = Keyword.get(opts, :interval_ms, 1_000)
        app_starter = Keyword.get(opts, :app_starter, &Application.ensure_all_started/1)

        Application.put_env(:symphony_1, :queue_runtime, %{
          enabled: true,
          interval_ms: interval_ms,
          run_attrs: run_attrs
        })

        Logger.info(
          "symphony.runtime: starting continuous queue (team=#{run_attrs.linear_config.team_key}, interval=#{interval_ms}ms)"
        )

        {:ok, _apps} = app_starter.(:symphony_1)
        {:ok, %{run_attrs: run_attrs}}
      end
    end
  end

  defp maybe_put_allowed_issue_identifiers(attrs, nil), do: attrs

  defp maybe_put_allowed_issue_identifiers(attrs, identifiers) when is_list(identifiers) do
    Map.put(attrs, :allowed_issue_identifiers, identifiers)
  end

  @spec build_run_attrs(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def build_run_attrs(cwd \\ File.cwd!(), graph_path \\ @graph_path) do
    workflow_path = workflow_path(cwd)

    with {:ok, intent} <- SetupIntent.load(Path.join(cwd, @setup_intent_path)),
         :ok <- ensure_workflow_exists(workflow_path),
         {:ok, workflow} <- Policy.load_workflow_config(workflow_path),
         {:ok, graph, resolved_graph_path} <- load_graph_if_present(cwd, graph_path) do
      graph_path = if graph, do: resolved_graph_path, else: nil

      team_key = get_in(intent, ["linear", "team_key"])

      with {:ok, linear_config} <- RuntimeConfig.linear_config(team_key) do
        {:ok,
         %{
           base_branch: Workspace.resolve_base_branch(cwd),
           body: "Implements the claimed issue.",
           graph: graph,
           graph_path: graph_path,
           linear_config: linear_config,
           project_type: get_in(intent, ["project", "type"]) || "symphony",
           repo: get_in(intent, ["github", "repo"]),
           source_repo: cwd,
           title: "Implement claimed issue",
           worker_timeout_ms: get_in(workflow, ["codex", "turn_timeout_ms"]) || 300_000,
           workflow_path: workflow_path,
           workspace_root: WorkspaceRoot.resolve(cwd, workflow, intent)
         }}
      end
    end
  end

  defp workflow_path(cwd) do
    Path.join(cwd, @workflow_path)
  end

  defp ensure_workflow_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, {:workflow_not_found, path}}
  end

  defp load_graph_if_present(cwd, graph_path) do
    graph_path = Path.expand(graph_path, cwd)

    case Graph.load(graph_path) do
      {:ok, graph} ->
        Logger.info("symphony.runtime: loaded planning graph (#{length(graph.tasks)} tasks)")
        {:ok, graph, graph_path}

      {:error, :file_not_found} ->
        {:ok, nil, nil}

      {:error, reason} ->
        Logger.warning(
          "symphony.runtime: planning graph is present but invalid: #{inspect(reason)}"
        )

        {:error, {:invalid_graph, reason}}
    end
  end

  defp wait_for_active_runs(queue_scheduler, timeout_ms, run_attrs) do
    {results, failures} =
      queue_scheduler.active_runs
      |> Enum.map(fn {_ref, entry} ->
        task = entry.task

        case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          {:exit, reason} -> {:error, {:task_crashed, reason}}
          nil -> recover_timed_out_run(entry, run_attrs)
        end
      end)
      |> Enum.reduce({[], []}, fn
        {:ok, result}, {results, failures} ->
          {[result | results], failures}

        {:error, _reason} = error, {results, failures} ->
          {results, [error | failures]}

        result, {results, failures} ->
          {[result | results], failures}
      end)

    case failures do
      [] -> {:ok, Enum.reverse(results)}
      _ -> {:error, Enum.reverse(failures), Enum.reverse(results)}
    end
  end

  defp recover_timed_out_run(%{metadata: %{issue: issue}}, run_attrs) do
    RunCoordinator.recover_timed_out_issue(issue, run_attrs)
  end

  defp recover_timed_out_run(%{metadata: %{issue_identifier: issue_identifier}}, _run_attrs) do
    {:error, {:task_timeout, issue_identifier}}
  end

  defp recover_timed_out_run(_entry, _run_attrs), do: {:error, :task_timeout}
end
