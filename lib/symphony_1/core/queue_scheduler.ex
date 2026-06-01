defmodule Symphony1.Core.QueueScheduler do
  defstruct active_runs: %{}, launcher: nil, max_concurrent_agents: 1, error_reporter: nil

  @type t :: %__MODULE__{
          active_runs: %{reference() => %{task: Task.t(), metadata: map()}},
          launcher: (map() -> {:ok, Task.t()} | {:ok, Task.t(), map()} | :none | {:error, term()}),
          max_concurrent_agents: pos_integer(),
          error_reporter: (term() -> term())
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    max_concurrent_agents =
      opts
      |> Keyword.get(:max_concurrent_agents, 1)
      |> validate_max_concurrent_agents!()

    %__MODULE__{
      active_runs: %{},
      launcher: Keyword.fetch!(opts, :launcher),
      max_concurrent_agents: max_concurrent_agents,
      error_reporter: Keyword.get(opts, :error_reporter, fn _event -> :ok end)
    }
  end

  @spec drain_once(t(), map()) :: t()
  def drain_once(%__MODULE__{} = state, attrs) do
    {state, _report} = drain_once_with_report(state, attrs)
    state
  end

  @spec drain_once_with_report(t(), map()) :: {t(), map()}
  def drain_once_with_report(%__MODULE__{} = state, attrs) do
    open_slots = max(state.max_concurrent_agents - map_size(state.active_runs), 0)
    team_key = Map.get(attrs, :team_key)

    if open_slots == 0 do
      {state,
       %{
         status: :skipped,
         team_key: team_key,
         active_run_count: map_size(state.active_runs),
         launched_count: 0,
         issue_identifiers: active_issue_identifiers(state.active_runs),
         summary: skipped_summary(team_key, map_size(state.active_runs))
       }}
    else
      do_drain(state, attrs, open_slots, 0, [], team_key)
    end
  end

  defp validate_max_concurrent_agents!(value) when is_integer(value) and value > 0, do: value

  defp validate_max_concurrent_agents!(value) do
    raise ArgumentError,
          "max_concurrent_agents must be a positive integer, got: #{inspect(value)}"
  end

  defp do_drain(state, _attrs, 0, launched_count, launched_issue_identifiers, team_key) do
    {state,
     %{
       status: :success,
       team_key: team_key,
       active_run_count: map_size(state.active_runs),
       launched_count: launched_count,
       issue_identifiers: Enum.reverse(launched_issue_identifiers),
       summary: success_summary(Enum.reverse(launched_issue_identifiers), launched_count)
     }}
  end

  defp do_drain(state, attrs, open_slots, launched_count, launched_issue_identifiers, team_key) do
    case state.launcher.(attrs) do
      {:ok, %Task{} = task} ->
        entry = %{task: task, metadata: %{}}

        do_drain(
          %{state | active_runs: Map.put(state.active_runs, task.ref, entry)},
          attrs,
          open_slots - 1,
          launched_count + 1,
          launched_issue_identifiers,
          team_key
        )

      {:ok, %Task{} = task, metadata} when is_map(metadata) ->
        entry = %{task: task, metadata: metadata}

        do_drain(
          %{state | active_runs: Map.put(state.active_runs, task.ref, entry)},
          attrs,
          open_slots - 1,
          launched_count + 1,
          maybe_add_issue_identifier(launched_issue_identifiers, metadata),
          team_key
        )

      :none ->
        report =
          if launched_count == 0 do
            %{
              status: :no_work,
              team_key: team_key,
              active_run_count: map_size(state.active_runs),
              launched_count: 0,
              issue_identifiers: [],
              summary: no_work_summary(team_key)
            }
          else
            %{
              status: :success,
              team_key: team_key,
              active_run_count: map_size(state.active_runs),
              launched_count: launched_count,
              issue_identifiers: Enum.reverse(launched_issue_identifiers),
              summary: success_summary(Enum.reverse(launched_issue_identifiers), launched_count)
            }
          end

        {state, report}

      {:error, reason} ->
        state.error_reporter.({:launch_failed, reason, attrs})

        {state,
         %{
           status: :failure,
           team_key: team_key,
           active_run_count: map_size(state.active_runs),
           launched_count: launched_count,
           issue_identifiers: Enum.reverse(launched_issue_identifiers),
           reason: reason,
           summary: failure_summary(reason, launched_count, launched_issue_identifiers)
         }}
    end
  end

  defp active_issue_identifiers(active_runs) do
    active_runs
    |> Map.values()
    |> Enum.reduce([], fn %{metadata: metadata}, acc -> maybe_add_issue_identifier(acc, metadata) end)
    |> Enum.reverse()
  end

  defp maybe_add_issue_identifier(issue_identifiers, metadata) do
    case issue_identifier_from_metadata(metadata) do
      nil -> issue_identifiers
      issue_identifier -> [issue_identifier | issue_identifiers]
    end
  end

  defp issue_identifier_from_metadata(metadata) when is_map(metadata) do
    Map.get(metadata, :issue_identifier) || get_in(metadata, [:issue, :identifier])
  end

  defp issue_identifier_from_metadata(_metadata), do: nil

  defp skipped_summary(nil, active_run_count) do
    "Queue drain skipped: #{active_run_count} active #{run_word(active_run_count)} already #{fill_word(active_run_count)} all available slots."
  end

  defp skipped_summary(team_key, active_run_count) do
    "Queue drain skipped for team #{team_key}: #{active_run_count} active #{run_word(active_run_count)} already #{fill_word(active_run_count)} all available slots."
  end

  defp no_work_summary(nil), do: "Queue drain found no claimable issues."
  defp no_work_summary(team_key), do: "Queue drain found no claimable issues for team #{team_key}."

  defp success_summary([issue_identifier], 1),
    do: "Queue drain launched 1 issue run for #{issue_identifier}."

  defp success_summary([], 1), do: "Queue drain launched 1 issue run."

  defp success_summary(issue_identifiers, count) do
    if issue_identifiers == [] do
      "Queue drain launched #{count} issue runs."
    else
      "Queue drain launched #{count} issue runs for #{Enum.join(issue_identifiers, ", ")}."
    end
  end

  defp failure_summary(reason, 0, []),
    do: "Queue drain failed before launching work: #{inspect(reason)}."

  defp failure_summary(reason, launched_count, []) do
    "Queue drain failed after launching #{launched_count} issue #{run_word(launched_count)}: #{inspect(reason)}."
  end

  defp failure_summary(reason, launched_count, launched_issue_identifiers) do
    "Queue drain failed after launching #{launched_count} issue #{run_word(launched_count)} for #{Enum.join(Enum.reverse(launched_issue_identifiers), ", ")}: #{inspect(reason)}."
  end

  defp run_word(1), do: "run"
  defp run_word(_count), do: "runs"

  defp fill_word(1), do: "fills"
  defp fill_word(_count), do: "fill"
end
