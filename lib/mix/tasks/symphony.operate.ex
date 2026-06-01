defmodule Mix.Tasks.Symphony.Operate do
  use Mix.Task

  alias Symphony1.Planning.{Graph, Status}
  alias Symphony1.Observability.{Recorder, StaleGraphGuard}
  alias Symphony1.RuntimeConfig

  @shortdoc "Supervised foreground operator runtime — continuously observe and advance the planning graph"

  @default_interval_seconds 30
  @active_linear_states ["Todo", "In Progress", "Finalizing", "Human Review", "Merging"]

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          graph: :string,
          team_key: :string,
          interval_seconds: :integer,
          auto_rework: :boolean,
          auto_rework_continue: :boolean
        ]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil ->
          Mix.raise(
            "usage: mix symphony.operate --graph PATH --team-key KEY [--interval-seconds N]"
          )

        path ->
          path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil ->
          Mix.raise(
            "usage: mix symphony.operate --graph PATH --team-key KEY [--interval-seconds N]"
          )

        key ->
          key
      end

    interval = parse_interval(opts)
    interval_ms = interval * 1000
    cwd = Keyword.get_lazy(opts, :cwd, fn -> StaleGraphGuard.repo_root_for_graph(graph_path) end)

    tick_opts = [
      auto_rework: Keyword.get(opts, :auto_rework, false),
      auto_rework_continue: Keyword.get(opts, :auto_rework_continue, false)
    ]

    tick_fn = Application.get_env(:symphony_1, :operate_tick_fn, &run_tick/4)

    should_continue =
      Application.get_env(:symphony_1, :operate_should_continue, &default_should_continue/0)

    sleep_fn = Application.get_env(:symphony_1, :operate_sleep_fn, &Process.sleep/1)

    # First tick, then loop: tick → sleep → check continue → repeat
    run_tick_with_cwd(tick_fn, graph_path, team_key, cwd, tick_opts)

    run_loop(
      graph_path,
      team_key,
      cwd,
      tick_opts,
      interval_ms,
      tick_fn,
      should_continue,
      sleep_fn
    )
  end

  @doc false
  def parse_interval(opts) do
    Keyword.get(opts, :interval_seconds, @default_interval_seconds)
  end

  defp run_loop(
         graph_path,
         team_key,
         cwd,
         tick_opts,
         interval_ms,
         tick_fn,
         should_continue,
         sleep_fn
       ) do
    sleep_fn.(interval_ms)

    if should_continue.() do
      run_tick_with_cwd(tick_fn, graph_path, team_key, cwd, tick_opts)

      run_loop(
        graph_path,
        team_key,
        cwd,
        tick_opts,
        interval_ms,
        tick_fn,
        should_continue,
        sleep_fn
      )
    end
  end

  @doc false
  def run_tick(graph_path, team_key),
    do: run_tick(graph_path, team_key, StaleGraphGuard.repo_root_for_graph(graph_path))

  @doc false
  def run_tick(graph_path, team_key, cwd), do: run_tick(graph_path, team_key, cwd, [])

  @doc false
  def run_tick(graph_path, team_key, cwd, opts) do
    cycle_id = Recorder.new_cycle_id()
    cycle_context = cycle_context(graph_path, team_key, cwd, opts, cycle_id)

    record_tick_event(cycle_context, "operate_tick_started", "operate")

    graph =
      case Graph.load(graph_path) do
        {:ok, g} -> g
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    candidates = Graph.stale_in_progress_tasks(graph)
    summary = Status.summarize(graph)

    case StaleGraphGuard.check(cwd, graph_path, graph) do
      {:error, error} ->
        Mix.shell().info(Status.format(summary))

        record_tick_event(
          cycle_context,
          "operate_tick_status",
          "operate",
          %{summary: summary, stale_candidate_count: length(candidates)},
          summary
        )

        Mix.shell().info("operate: stale graph regression detected — advancement paused")
        Mix.shell().info("operate: " <> error.recovery_action)

        record_tick_event(
          cycle_context,
          "operate_tick_paused",
          "operate",
          %{
            reason: "stale_graph_regression_detected",
            stale_regressions: error.regressions
          },
          summary
        )

      :ok ->
        findings =
          if candidates != [] do
            compute_findings(candidates, team_key)
          else
            %{}
          end

        # Only pass non-active findings to status for stale annotations
        stale_findings = Map.reject(findings, fn {_id, outcome} -> outcome == :active end)

        Mix.shell().info(Status.format(summary, stale_findings))

        record_tick_event(
          cycle_context,
          "operate_tick_status",
          "operate",
          %{summary: summary, stale_candidate_count: length(candidates)},
          summary
        )

        if stale_findings != %{} do
          Mix.shell().info("operate: stale graph drift detected — advancement paused")

          Mix.shell().info(
            "operate: run mix symphony.plan_reconcile --graph #{graph_path} --team-key #{team_key}"
          )

          record_tick_event(
            cycle_context,
            "operate_tick_paused",
            "operate",
            %{
              reason: "stale_graph_drift_detected",
              stale_findings: stale_findings_details(graph, stale_findings)
            },
            summary
          )
        else
          # No stale findings — safe to advance one cycle pass
          linear_config = build_linear_config(team_key)

          plan_cycle_runner =
            Application.get_env(
              :symphony_1,
              :operate_plan_cycle_runner,
              &Mix.Tasks.Symphony.PlanCycle.run_cycle/5
            )

          issue_fetcher = Application.get_env(:symphony_1, :plan_sync_issue_fetcher)
          issue_creator = Application.get_env(:symphony_1, :plan_materializer_issue_creator)

          sync_opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []
          mat_opts = if issue_creator, do: [issue_creator: issue_creator], else: []

          record_tick_event(
            cycle_context,
            "operate_tick_advancing",
            "operate",
            %{reason: "no_stale_graph_drift_detected"},
            summary
          )

          plan_cycle_runner.(graph_path, linear_config, sync_opts, mat_opts,
            cwd: cwd,
            cycle_id: cycle_id,
            auto_rework: Keyword.get(opts, :auto_rework, false),
            auto_rework_continue: Keyword.get(opts, :auto_rework_continue, false)
          )
        end
    end
  end

  defp run_tick_with_cwd(tick_fn, graph_path, team_key, cwd, opts) do
    case :erlang.fun_info(tick_fn, :arity) do
      {:arity, 4} -> tick_fn.(graph_path, team_key, cwd, opts)
      {:arity, 3} -> tick_fn.(graph_path, team_key, cwd)
      {:arity, 2} -> tick_fn.(graph_path, team_key)
    end
  end

  defp build_linear_config(team_key) do
    case RuntimeConfig.linear_config(team_key) do
      {:ok, config} ->
        config

      {:error, :missing_linear_api_key} ->
        Mix.raise(RuntimeConfig.missing_linear_api_key_message())
    end
  end

  defp compute_findings(candidates, team_key) do
    linear_config = build_linear_config(team_key)

    issue_fetcher =
      Application.get_env(:symphony_1, :operate_issue_fetcher)

    fetch_fn = if issue_fetcher, do: issue_fetcher, else: &default_issue_fetcher/1

    issue_state_map =
      case fetch_fn.(linear_config) do
        {:ok, issues} ->
          Map.new(issues, fn i -> {i.identifier, i.state} end)

        {:error, reason} ->
          Mix.raise("operate: failed to fetch Linear issues: #{inspect(reason)}")
      end

    Map.new(candidates, fn task ->
      identifier = task.materialization.linear_issue_identifier
      linear_state = Map.get(issue_state_map, identifier)
      {task.id, classify(linear_state)}
    end)
  end

  defp classify(nil), do: :missing
  defp classify("Done"), do: :done
  defp classify("Rework"), do: :rework
  defp classify(state) when state in @active_linear_states, do: :active
  defp classify(_unknown), do: :active

  defp default_should_continue do
    # In production, this always returns true (loop forever).
    # For tests, override via :operate_should_continue Application env.
    true
  end

  defp default_issue_fetcher(config) do
    case Symphony1.Core.Linear.list_team_issues(config) do
      {:ok, issues} ->
        {:ok,
         Enum.map(issues, fn issue -> %{identifier: issue.identifier, state: issue.state} end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cycle_context(graph_path, team_key, cwd, opts, cycle_id) do
    %{
      cycle_id: cycle_id,
      graph_path: graph_path,
      team_key: team_key,
      cwd: cwd,
      auto_rework: Keyword.get(opts, :auto_rework, false),
      auto_rework_continue: Keyword.get(opts, :auto_rework_continue, false)
    }
  end

  defp stale_findings_details(graph, stale_findings) do
    graph.tasks
    |> Enum.filter(&Map.has_key?(stale_findings, &1.id))
    |> Enum.map(fn task ->
      %{
        task_id: task.id,
        issue_identifier: task.materialization.linear_issue_identifier,
        outcome: stale_findings |> Map.fetch!(task.id) |> to_string()
      }
    end)
  end

  defp record_tick_event(cycle_context, event, phase, details \\ %{}, summary \\ nil, opts \\ []) do
    Recorder.record_cycle(cycle_context.cwd, event,
      context: cycle_context,
      phase: phase,
      details: details,
      summary: summary,
      severity: Keyword.get(opts, :severity, "info")
    )
  end
end
