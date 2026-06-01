defmodule Mix.Tasks.Symphony.PlanCycle do
  use Mix.Task

  alias Symphony1.Core.Linear
  alias Symphony1.Observability.{Recorder, StaleGraphGuard, StuckExplanation}

  alias Symphony1.Planning.{
    Feedback,
    Graph,
    GraphCheckpoint,
    Materializer,
    ReworkContinuation,
    Status
  }

  alias Symphony1.RuntimeConfig

  @shortdoc "Run one full graph-driven happy-path cycle: sync -> materialize -> run -> review -> merge -> resync"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          cwd: :string,
          graph: :string,
          team_key: :string,
          once: :boolean,
          auto_rework: :boolean,
          auto_rework_continue: :boolean
        ]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_cycle --graph PATH --team-key KEY --once")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_cycle --graph PATH --team-key KEY --once")
        key -> key
      end

    unless Keyword.get(opts, :once, false) do
      Mix.raise("--once is required in the current version of plan_cycle")
    end

    # Validate the graph path before touching live config so local input errors
    # remain testable without exported credentials.
    case Graph.load(graph_path) do
      {:ok, _graph} -> :ok
      {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
    end

    issue_fetcher = Application.get_env(:symphony_1, :plan_sync_issue_fetcher)
    issue_creator = Application.get_env(:symphony_1, :plan_materializer_issue_creator)

    sync_opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []
    mat_opts = if issue_creator, do: [issue_creator: issue_creator], else: []

    config_loader =
      Application.get_env(
        :symphony_1,
        :plan_cycle_linear_config_loader,
        &RuntimeConfig.linear_config!/1
      )

    linear_config = config_loader.(team_key)

    cwd = Keyword.get_lazy(opts, :cwd, fn -> StaleGraphGuard.repo_root_for_graph(graph_path) end)

    run_cycle(graph_path, linear_config, sync_opts, mat_opts,
      cwd: cwd,
      auto_rework: Keyword.get(opts, :auto_rework, false),
      auto_rework_continue: Keyword.get(opts, :auto_rework_continue, false)
    )
  end

  @doc """
  Runs one full happy-path cycle. Callable from other commands (e.g. operate).
  """
  def run_cycle(graph_path, linear_config, sync_opts \\ [], mat_opts \\ [], opts \\ []) do
    cwd = Keyword.get_lazy(opts, :cwd, fn -> StaleGraphGuard.repo_root_for_graph(graph_path) end)
    auto_rework? = Keyword.get(opts, :auto_rework, false)
    auto_rework_continue? = Keyword.get(opts, :auto_rework_continue, false)

    graph_writer =
      Application.get_env(:symphony_1, :plan_materializer_graph_writer, &Graph.persist/2)

    recovery_snapshot_writer =
      Application.get_env(
        :symphony_1,
        :plan_materializer_recovery_snapshot_writer,
        &Materializer.default_recovery_snapshot_writer/1
      )

    mat_opts =
      mat_opts
      |> Keyword.put_new(:graph_path, graph_path)
      |> Keyword.put_new(:graph_writer, graph_writer)
      |> Keyword.put_new(:recovery_snapshot_writer, recovery_snapshot_writer)

    cycle_context =
      cycle_context(graph_path, linear_config, cwd, auto_rework?, auto_rework_continue?, opts)

    record_cycle_event(cycle_context, "plan_cycle_started", "plan_cycle")

    # Step 1: Load graph
    graph =
      case Graph.load(graph_path) do
        {:ok, g} -> g
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    # Step 2: Sync
    {graph, linear_states} =
      case Feedback.sync(graph, linear_config, sync_opts) do
        {:ok, result} ->
          if result.updated != [] do
            :ok = Graph.write(result.graph, graph_path)
            Mix.shell().info("plan_cycle: synced #{length(result.updated)} task(s)")
          end

          record_cycle_event(
            cycle_context,
            "plan_cycle_sync_finished",
            "sync",
            %{
              step: "initial",
              updated_count: length(result.updated),
              updated: result.updated
            },
            Status.summarize(result.graph)
          )

          {result.graph, result.issue_states}

        {:error, reason} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_sync_failed",
            "sync",
            %{step: "initial", reason: inspect(reason)},
            nil,
            severity: "error"
          )

          Mix.raise("plan_cycle: sync failed: #{inspect(reason)}")
      end

    {graph, linear_states} =
      cond do
        auto_rework_continue? ->
          {updated_graph, continued_linear_states} =
            continue_rework_tasks(graph, graph_path, linear_config, auto_rework?)

          {updated_graph, Map.merge(linear_states, continued_linear_states)}

        auto_rework? ->
          {retry_rework_tasks(graph, graph_path), linear_states}

        true ->
          {graph, linear_states}
      end

    # Step 3: Pre-cycle status
    summary = Status.summarize(graph)
    Mix.shell().info(Status.format(summary))

    record_cycle_event(
      cycle_context,
      "plan_cycle_status",
      "plan_cycle",
      %{summary: summary},
      summary
    )

    # Step 4: Materialize (only if there are ready tasks)
    if summary.ready == [] do
      runnable_existing_identifiers = runnable_existing_issue_identifiers(summary, linear_states)

      run_result =
        if runnable_existing_identifiers == [] do
          Mix.shell().info(
            "plan_cycle: no ready work — still checking review and merge this tick"
          )

          record_cycle_event(
            cycle_context,
            "plan_cycle_no_ready_work",
            "plan_cycle",
            %{summary: summary},
            summary
          )

          %{results: []}
        else
          Mix.shell().info(
            "plan_cycle: running #{length(runnable_existing_identifiers)} already-materialized task(s)"
          )

          record_cycle_event(
            cycle_context,
            "plan_cycle_continuing_materialized_work",
            "run",
            %{issue_identifiers: runnable_existing_identifiers},
            summary
          )

          runtime_runner =
            Application.get_env(:symphony_1, :plan_cycle_runtime_runner, &Symphony1.Runtime.run/1)

          case runtime_runner.(
                 once: true,
                 cwd: cwd,
                 graph_path: graph_path,
                 allowed_issue_identifiers: runnable_existing_identifiers
               ) do
            {:ok, result} ->
              Mix.shell().info("plan_cycle: run complete (#{length(result.results)} result(s))")

              record_cycle_event(
                cycle_context,
                "plan_cycle_run_finished",
                "run",
                %{
                  result_count: length(result.results),
                  issue_identifiers: extract_issue_identifiers(result.results)
                },
                summary
              )

              result

            {:error, reason} ->
              record_cycle_event(
                cycle_context,
                "plan_cycle_run_failed",
                "run",
                %{reason: inspect(reason)},
                summary,
                severity: "error"
              )

              handle_run_failure(
                graph_path,
                linear_config,
                sync_opts,
                reason,
                auto_rework? or auto_rework_continue?,
                cycle_context
              )
          end
        end

      review_and_merge =
        run_review_and_merge(cycle_context, graph_path, linear_config, sync_opts, summary)

      if run_result.results == [] do
        maybe_log_stuck_explanation(
          cycle_context,
          summary,
          0,
          0,
          linear_states,
          review_and_merge
        )
      end

      final_sync_and_status(graph_path, linear_config, sync_opts, cycle_context)
    else
      case StaleGraphGuard.check(cwd, graph_path, graph) do
        :ok ->
          :ok

        {:error, error} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_stale_graph_regression_detected",
            "materialization",
            %{
              stale_regressions: error.regressions,
              recovery_action: error.recovery_action
            },
            summary,
            severity: "error"
          )

          Mix.raise(StaleGraphGuard.error_message(error))
      end

      {materialized_count, materialized_summary} =
        case Materializer.materialize_and_persist(graph, linear_config, graph_path, mat_opts) do
          {:ok, result} ->
            materialized_count = length(result.materialized)
            invalid_tasks = Map.get(result, :invalid_tasks, [])
            materialized_summary = Status.summarize(result.graph)

            Mix.shell().info("plan_cycle: materialized #{materialized_count} task(s)")

            if invalid_tasks != [] do
              Mix.shell().info(
                "plan_cycle: skipped #{length(invalid_tasks)} invalid ready task(s)"
              )
            end

            record_cycle_event(
              cycle_context,
              "plan_cycle_materialized",
              "materialization",
              %{
                count: materialized_count,
                tasks: result.materialized,
                skipped: result.skipped,
                invalid_tasks: invalid_tasks
              },
              materialized_summary,
              graph: result.graph
            )

            {materialized_count, materialized_summary}

          {:error, error} ->
            materialized_summary = Status.summarize(error.graph)

            failure_reason =
              if Map.has_key?(error, :persistence_failure) do
                {:graph_write_failed, error.persistence_failure.graph_write_error}
              else
                error.reason
              end

            record_cycle_event(
              cycle_context,
              "plan_cycle_materialization_failed",
              "materialization",
              %{
                failed_task_id: Map.get(error, :failed_task_id),
                reason: inspect(failure_reason),
                materialized: error.materialized,
                skipped: error.skipped,
                persistence_failure: Map.get(error, :persistence_failure)
              },
              materialized_summary,
              graph: error.graph,
              severity: "error"
            )

            if error.materialized != [] do
              Mix.shell().info(
                "plan_cycle: partial: materialized #{length(error.materialized)} task(s) before failure"
              )
            end

            Mix.raise(Materializer.materialization_error_message(error, prefix: "plan_cycle: "))
        end

      # Step 5: Run once
      runtime_runner =
        Application.get_env(:symphony_1, :plan_cycle_runtime_runner, &Symphony1.Runtime.run/1)

      allowed_issue_identifiers = runnable_issue_identifiers(materialized_summary)

      run_result =
        case runtime_runner.(
               once: true,
               cwd: cwd,
               graph_path: graph_path,
               allowed_issue_identifiers: allowed_issue_identifiers
             ) do
          {:ok, result} ->
            Mix.shell().info("plan_cycle: run complete (#{length(result.results)} result(s))")

            record_cycle_event(
              cycle_context,
              "plan_cycle_run_finished",
              "run",
              %{
                result_count: length(result.results),
                issue_identifiers: extract_issue_identifiers(result.results)
              },
              materialized_summary
            )

            result

          {:error, reason} ->
            record_cycle_event(
              cycle_context,
              "plan_cycle_run_failed",
              "run",
              %{reason: inspect(reason)},
              materialized_summary,
              severity: "error"
            )

            handle_run_failure(
              graph_path,
              linear_config,
              sync_opts,
              reason,
              auto_rework? or auto_rework_continue?,
              cycle_context
            )
        end

      # Step 6: Review once and merge once. These runtimes are safe no-op checks
      # when no Human Review or approved merge work exists, so they must run even
      # after restarts where this tick did not produce fresh worker output.
      review_and_merge =
        run_review_and_merge(
          cycle_context,
          graph_path,
          linear_config,
          sync_opts,
          materialized_summary
        )

      if run_result.results == [] do
        record_cycle_event(
          cycle_context,
          "plan_cycle_no_run_results",
          "plan_cycle",
          %{
            reason: "run produced no results",
            materialized_count: materialized_count,
            run_result_count: 0
          },
          materialized_summary
        )

        maybe_log_stuck_explanation(
          cycle_context,
          summary,
          materialized_count,
          0,
          linear_states,
          review_and_merge
        )
      end

      final_sync_and_status(graph_path, linear_config, sync_opts, cycle_context)
    end
  end

  defp retry_rework_tasks(graph, graph_path) do
    rework_tasks = Enum.filter(graph.tasks, &(&1.status == "rework"))

    case Enum.reduce_while(rework_tasks, {:ok, graph, []}, &retry_rework_task/2) do
      {:ok, updated_graph, retried_ids} ->
        if retried_ids != [] do
          :ok = Graph.write(updated_graph, graph_path)
          Mix.shell().info("plan_cycle: auto-retried #{length(retried_ids)} rework task(s)")
        end

        updated_graph

      {:error, task_id, reason} ->
        Mix.raise("plan_cycle: auto-rework failed on #{task_id}: #{inspect(reason)}")
    end
  end

  defp retry_rework_task(task, {:ok, graph, retried_ids}) do
    case Graph.retry_task(graph, task.id) do
      {:ok, updated_graph} -> {:cont, {:ok, updated_graph, retried_ids ++ [task.id]}}
      {:error, reason} -> {:halt, {:error, task.id, reason}}
    end
  end

  defp continue_rework_tasks(graph, graph_path, linear_config, fallback_clean?) do
    rework_tasks = Enum.filter(graph.tasks, &(&1.status == "rework"))

    case Enum.reduce_while(
           rework_tasks,
           {:ok, graph, %{continued: [], clean_retried: [], continued_linear_states: %{}}},
           &continue_rework_task(&1, &2, linear_config, fallback_clean?)
         ) do
      {:ok, updated_graph, counts} ->
        if counts.continued != [] or counts.clean_retried != [] do
          :ok = Graph.write(updated_graph, graph_path)

          if counts.continued != [] do
            Mix.shell().info("plan_cycle: continued #{length(counts.continued)} rework task(s)")
          end

          if counts.clean_retried != [] do
            Mix.shell().info(
              "plan_cycle: clean-retried #{length(counts.clean_retried)} rework task(s)"
            )
          end
        end

        {updated_graph, counts.continued_linear_states}

      {:error, task_id, reason} ->
        Mix.raise("plan_cycle: auto-rework-continue failed on #{task_id}: #{inspect(reason)}")
    end
  end

  defp continue_rework_task(task, {:ok, graph, counts}, linear_config, fallback_clean?) do
    with {:ok, decision} <- ReworkContinuation.classify(graph, task.id),
         {:ok, issue} <- transition_rework_issue_to_todo(decision, linear_config),
         {:ok, updated_graph} <- Graph.continue_rework_task(graph, task.id) do
      continued_linear_states =
        Map.put(
          counts.continued_linear_states,
          decision.issue_identifier,
          Map.get(issue, :state, "Todo")
        )

      {:cont,
       {:ok, updated_graph,
        %{
          counts
          | continued: counts.continued ++ [task.id],
            continued_linear_states: continued_linear_states
        }}}
    else
      {:error, reason} ->
        maybe_clean_retry_rework_task(task, graph, counts, reason, fallback_clean?)
    end
  end

  defp transition_rework_issue_to_todo(decision, linear_config) do
    transitioner =
      Application.get_env(
        :symphony_1,
        :plan_rework_continuation_transitioner,
        &default_rework_continuation_transitioner/3
      )

    issue = %{
      id: decision.issue_id,
      identifier: decision.issue_identifier,
      state: "Rework"
    }

    transitioner.(issue, "Todo", linear_config)
  end

  defp default_rework_continuation_transitioner(issue, target_state, linear_config) do
    Linear.transition_issue(issue, target_state, linear_config)
  end

  defp maybe_clean_retry_rework_task(task, graph, counts, _reason, true) do
    case Graph.retry_task(graph, task.id) do
      {:ok, updated_graph} ->
        {:cont,
         {:ok, updated_graph, %{counts | clean_retried: counts.clean_retried ++ [task.id]}}}

      {:error, retry_reason} ->
        {:halt, {:error, task.id, retry_reason}}
    end
  end

  defp maybe_clean_retry_rework_task(task, _graph, _counts, reason, false) do
    {:halt, {:error, task.id, reason}}
  end

  defp runnable_issue_identifiers(summary) do
    (summary.ready ++ summary.in_progress)
    |> Enum.map(& &1.linear)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp runnable_existing_issue_identifiers(summary, linear_states) do
    summary.in_progress
    |> Enum.map(& &1.linear)
    |> Enum.filter(&(Map.get(linear_states, &1) == "Todo"))
    |> Enum.uniq()
  end

  defp run_review_and_merge(cycle_context, graph_path, linear_config, sync_opts, summary) do
    review_runner =
      Application.get_env(
        :symphony_1,
        :plan_cycle_review_runner,
        &Symphony1.ReviewRuntime.run/1
      )

    review_result_count =
      case review_runner.(once: true, cwd: cycle_context.cwd, graph_path: graph_path) do
        {:ok, result} ->
          Mix.shell().info("plan_cycle: review complete (#{length(result.results)} result(s))")

          record_cycle_event(
            cycle_context,
            "plan_cycle_review_finished",
            "review",
            %{
              result_count: length(result.results),
              outcomes: review_outcomes(result.results)
            },
            summary
          )

          length(result.results)

        {:error, reason} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_review_failed",
            "review",
            %{reason: inspect(reason)},
            summary,
            severity: "error"
          )

          handle_review_failure(graph_path, linear_config, sync_opts, reason, cycle_context)
      end

    merge_runner =
      Application.get_env(
        :symphony_1,
        :plan_cycle_merge_runner,
        &Symphony1.MergeRuntime.run/1
      )

    merge_result_count =
      case merge_runner.(once: true, cwd: cycle_context.cwd) do
        {:ok, result} ->
          Mix.shell().info("plan_cycle: merge complete (#{length(result.results)} result(s))")

          record_cycle_event(
            cycle_context,
            "plan_cycle_merge_finished",
            "merge",
            %{
              result_count: length(result.results),
              issue_identifiers: extract_issue_identifiers(result.results)
            },
            summary
          )

          length(result.results)

        {:error, reason} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_merge_failed",
            "merge",
            %{reason: inspect(reason)},
            summary,
            severity: "error"
          )

          Mix.raise("plan_cycle: merge failed: #{inspect(reason)}")
      end

    %{
      review_result_count: review_result_count,
      merge_result_count: merge_result_count
    }
  end

  defp handle_review_failure(graph_path, linear_config, sync_opts, reason, cycle_context) do
    case sync_graph(graph_path, linear_config, sync_opts, cycle_context, "review_recovery") do
      {:ok, _graph} ->
        Mix.raise("plan_cycle: review failed: #{inspect(reason)}")

      {:error, sync_reason} ->
        Mix.raise(
          "plan_cycle: review failed: #{inspect(reason)} (recovery sync failed: #{inspect(sync_reason)})"
        )
    end
  end

  defp handle_run_failure(_graph_path, _linear_config, _sync_opts, reason, false, _cycle_context) do
    Mix.raise("plan_cycle: run failed: #{inspect(reason)}")
  end

  defp handle_run_failure(graph_path, linear_config, sync_opts, reason, true, cycle_context) do
    case sync_graph(graph_path, linear_config, sync_opts, cycle_context, "run_recovery") do
      {:ok, _graph} ->
        Mix.shell().info("plan_cycle: run failed and was recorded; continuing operator loop")
        Mix.shell().info("plan_cycle: failure reason: #{inspect(reason)}")
        %{results: []}

      {:error, sync_reason} ->
        Mix.raise(
          "plan_cycle: run failed: #{inspect(reason)} (recovery sync failed: #{inspect(sync_reason)})"
        )
    end
  end

  defp sync_graph(graph_path, linear_config, sync_opts, cycle_context, step) do
    with {:ok, fresh_graph} <- Graph.load(graph_path),
         {:ok, result} <- Feedback.sync(fresh_graph, linear_config, sync_opts) do
      if result.updated != [] do
        case Graph.write(result.graph, graph_path) do
          :ok ->
            record_sync_event(cycle_context, step, result)
            {:ok, result.graph}

          {:error, reason} ->
            {:error, {:graph_write_failed, reason}}
        end
      else
        record_sync_event(cycle_context, step, result)
        {:ok, result.graph}
      end
    end
  end

  defp final_sync_and_status(graph_path, linear_config, sync_opts, cycle_context) do
    fresh_graph =
      case Graph.load(graph_path) do
        {:ok, g} ->
          g

        {:error, reason} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_sync_failed",
            "sync",
            %{step: "final", reason: inspect(reason)},
            nil,
            severity: "error"
          )

          Mix.raise("plan_cycle: final sync failed — could not reload graph: #{inspect(reason)}")
      end

    case Feedback.sync(fresh_graph, linear_config, sync_opts) do
      {:ok, result} ->
        if result.updated != [] do
          :ok = Graph.write(result.graph, graph_path)
          Mix.shell().info("plan_cycle: final sync updated #{length(result.updated)} task(s)")
        end

        final_summary = Status.summarize(result.graph)

        record_cycle_event(
          cycle_context,
          "plan_cycle_sync_finished",
          "sync",
          %{
            step: "final",
            updated_count: length(result.updated),
            updated: result.updated
          },
          final_summary,
          graph: result.graph
        )

        Mix.shell().info(Status.format(final_summary))
        maybe_checkpoint_completed_graph(cycle_context, graph_path, final_summary)

      {:error, reason} ->
        record_cycle_event(
          cycle_context,
          "plan_cycle_sync_failed",
          "sync",
          %{step: "final", reason: inspect(reason)},
          nil,
          severity: "error"
        )

        Mix.raise("plan_cycle: final sync failed: #{inspect(reason)}")
    end
  end

  defp maybe_checkpoint_completed_graph(cycle_context, graph_path, final_summary) do
    if terminal_all_done?(final_summary) do
      checkpoint_fn =
        Application.get_env(
          :symphony_1,
          :plan_cycle_graph_checkpoint_fn,
          &GraphCheckpoint.checkpoint/2
        )

      case checkpoint_fn.(graph_path, []) do
        {:ok, :noop} ->
          record_cycle_event(
            cycle_context,
            "plan_cycle_graph_checkpoint_finished",
            "checkpoint",
            %{status: :noop},
            final_summary
          )

        {:ok, %{status: :committed} = result} ->
          Mix.shell().info(
            "plan_cycle: checkpointed completed graph state in Git (#{result.relative_graph_path} @ #{result.commit_sha})"
          )

          record_cycle_event(
            cycle_context,
            "plan_cycle_graph_checkpoint_finished",
            "checkpoint",
            result,
            final_summary
          )

        {:error, failure} ->
          IO.puts(
            "Warning: plan_cycle graph checkpoint failed at #{failure.stage}: #{String.trim(failure.output)}"
          )

          record_cycle_event(
            cycle_context,
            "plan_cycle_graph_checkpoint_failed",
            "checkpoint",
            failure,
            final_summary,
            severity: "warning"
          )
      end
    end
  end

  defp terminal_all_done?(summary) do
    summary.total > 0 and length(summary.done) == summary.total
  end

  defp maybe_log_stuck_explanation(
         cycle_context,
         summary,
         materialized_count,
         run_result_count,
         linear_states,
         review_and_merge
       ) do
    case StuckExplanation.explain(summary,
           cwd: cycle_context.cwd,
           graph_path: cycle_context.graph_path,
           team_key: cycle_context.team_key,
           materialized_count: materialized_count,
           run_result_count: run_result_count,
           review_result_count: Map.get(review_and_merge, :review_result_count, 0),
           merge_result_count: Map.get(review_and_merge, :merge_result_count, 0),
           linear_states: linear_states
         ) do
      {:stuck, details} ->
        Mix.shell().info("plan_cycle: stuck explanation — #{details.message}")
        record_cycle_event(cycle_context, "stuck_explanation", "stuck", details, summary)

      :ok ->
        :ok
    end
  end

  defp cycle_context(graph_path, linear_config, cwd, auto_rework?, auto_rework_continue?, opts) do
    cycle_id =
      case Keyword.get(opts, :cycle_id) do
        nil -> Recorder.new_cycle_id()
        provided -> provided
      end

    %{
      cycle_id: cycle_id,
      graph_path: graph_path,
      team_key: Map.get(linear_config, :team_key),
      cwd: cwd,
      auto_rework: auto_rework?,
      auto_rework_continue: auto_rework_continue?
    }
  end

  defp record_sync_event(nil, _step, _result), do: :ok

  defp record_sync_event(cycle_context, step, result) do
    record_cycle_event(
      cycle_context,
      "plan_cycle_sync_finished",
      "sync",
      %{
        step: step,
        updated_count: length(result.updated),
        updated: result.updated
      },
      Status.summarize(result.graph)
    )
  end

  defp record_cycle_event(cycle_context, event, phase, details \\ %{}, summary \\ nil, opts \\ []) do
    Recorder.record_cycle(cycle_context.cwd, event,
      context: cycle_context,
      phase: phase,
      details: details,
      summary: summary,
      graph: Keyword.get(opts, :graph),
      severity: Keyword.get(opts, :severity, "info")
    )
  end

  defp extract_issue_identifiers(results) do
    Enum.flat_map(results, fn result ->
      case get_in(result, [:issue, :identifier]) do
        nil -> []
        identifier -> [identifier]
      end
    end)
  end

  defp review_outcomes(results) do
    Enum.map(results, fn result ->
      %{
        issue_identifier: Map.get(result, :issue_identifier),
        outcome: Map.get(result, :outcome)
      }
    end)
  end
end
