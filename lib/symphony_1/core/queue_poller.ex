defmodule Symphony1.Core.QueuePoller do
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    state = %{
      drain_fun: Keyword.get(opts, :drain_fun, &Symphony1.Core.QueueScheduler.drain_once_with_report/2),
      interval_ms: Keyword.get(opts, :interval_ms, 1_000),
      queue_scheduler: Keyword.fetch!(opts, :queue_scheduler),
      result_reporter: Keyword.get(opts, :result_reporter, fn _event -> :ok end),
      run_attrs: Keyword.get(opts, :run_attrs, %{})
    }

    send(self(), :drain)
    {:ok, state}
  end

  @impl true
  def handle_info(:drain, state) do
    {queue_scheduler, drain_report} =
      normalize_drain_result(state.drain_fun.(state.queue_scheduler, state.run_attrs))

    if drain_report do
      state.result_reporter.({:drain_report, drain_report})
    end

    schedule_next_tick(state.interval_ms)
    {:noreply, %{state | queue_scheduler: queue_scheduler}}
  end

  def handle_info({ref, result}, %{queue_scheduler: %{active_runs: active_runs}} = state)
      when is_reference(ref) do
    if entry = Map.get(active_runs, ref) do
      metadata = ensure_issue_identifier(entry.metadata)
      Process.demonitor(ref, [:flush])
      state.result_reporter.({:run_finished, ref, result, metadata})
      state.result_reporter.({:run_report, classify_run_result(result, metadata)})
    end

    {:noreply,
     %{
       state
       | queue_scheduler: %{state.queue_scheduler | active_runs: Map.delete(active_runs, ref)}
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{queue_scheduler: %{active_runs: active_runs}} = state
      )
      when is_reference(ref) do
    if entry = Map.get(active_runs, ref) do
      metadata = ensure_issue_identifier(entry.metadata)
      state.result_reporter.({:run_down, ref, reason, metadata})
      state.result_reporter.({:run_report, down_report(reason, metadata)})
    end

    {:noreply,
     %{
       state
       | queue_scheduler: %{state.queue_scheduler | active_runs: Map.delete(active_runs, ref)}
     }}
  end

  defp schedule_next_tick(interval_ms) do
    Process.send_after(self(), :drain, interval_ms)
  end

  defp normalize_drain_result({queue_scheduler, report}) when is_map(report),
    do: {queue_scheduler, report}

  defp normalize_drain_result(queue_scheduler), do: {queue_scheduler, nil}

  defp ensure_issue_identifier(metadata) when is_map(metadata) do
    issue_identifier = Map.get(metadata, :issue_identifier) || get_in(metadata, [:issue, :identifier])

    if issue_identifier do
      Map.put(metadata, :issue_identifier, issue_identifier)
    else
      metadata
    end
  end

  defp ensure_issue_identifier(metadata), do: metadata

  defp classify_run_result({:error, reason}, metadata) do
    issue_identifier = Map.get(metadata, :issue_identifier)

    %{
      status: :failure,
      issue_identifier: issue_identifier,
      reason: reason,
      summary: "Queue run failed for #{issue_identifier || "unknown-issue"}: #{inspect(reason)}."
    }
  end

  defp classify_run_result({:ok, %{issue: %{identifier: issue_identifier, state: issue_state}}}, metadata) do
    %{
      status: :success,
      issue_identifier: Map.get(metadata, :issue_identifier) || issue_identifier,
      summary: "Queue run completed for #{issue_identifier} -> #{issue_state}."
    }
  end

  defp classify_run_result(result, metadata) do
    issue_identifier = Map.get(metadata, :issue_identifier)

    %{
      status: :failure,
      issue_identifier: issue_identifier,
      reason: {:unexpected_run_result, result},
      summary:
        "Queue run returned an unexpected result for #{issue_identifier || "unknown-issue"}: #{inspect(result)}."
    }
  end

  defp down_report(reason, metadata) do
    issue_identifier = Map.get(metadata, :issue_identifier)

    %{
      status: :failure,
      issue_identifier: issue_identifier,
      reason: reason,
      summary:
        "Queue run exited before reporting a result for #{issue_identifier || "unknown-issue"} (reason: #{inspect(reason)})."
    }
  end
end
