defmodule Symphony1.Observability.RunSummary do
  @moduledoc """
  Maintains a compact per-issue summary alongside the append-only run event log.
  """

  alias Symphony1.Observability.EventLog

  @default_last 50
  @schema_version 1
  @timeline_keys ~w(
    workspace_path
    branch
    base_branch
    pull_request_url
    elapsed_ms
    failure_reason
    command
    exit_status
    output_bytes
    output_tail
    stage
    outcome
  )

  @type events_report :: %{
          status: :ok | :missing,
          mode: :global | :issue,
          issue_identifier: String.t() | nil,
          summary: String.t(),
          events: [map()],
          total_events: non_neg_integer(),
          shown_events: non_neg_integer(),
          events_path: String.t(),
          summary_path: String.t() | nil
        }

  @spec default_last() :: pos_integer()
  def default_last, do: @default_last

  @spec path(String.t(), String.t()) :: String.t()
  def path(cwd, issue_identifier) do
    Path.join([cwd, "tmp", "symphony", "runs", issue_identifier, "summary.json"])
  end

  @spec events_report(String.t(), keyword()) :: events_report()
  def events_report(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    issue_identifier = normalize_optional_string(Keyword.get(opts, :issue))
    last = Keyword.get(opts, :last, @default_last)
    events_path = events_path(cwd, issue_identifier)
    summary_path = if issue_identifier, do: path(cwd, issue_identifier)

    case read_events(events_path) do
      {:ok, events} ->
        limited_events = take_last(events, last)

        %{
          status: :ok,
          mode: report_mode(issue_identifier),
          issue_identifier: issue_identifier,
          summary:
            build_summary(
              issue_identifier,
              load_summary_file(summary_path),
              events,
              limited_events
            ),
          events: limited_events,
          total_events: length(events),
          shown_events: length(limited_events),
          events_path: events_path,
          summary_path: summary_path
        }

      :missing ->
        %{
          status: :missing,
          mode: report_mode(issue_identifier),
          issue_identifier: issue_identifier,
          summary: missing_summary(issue_identifier),
          events: [],
          total_events: 0,
          shown_events: 0,
          events_path: events_path,
          summary_path: summary_path
        }
    end
  end

  @spec render_events_report(events_report()) :: String.t()
  def render_events_report(report) when is_map(report) do
    [
      "Symphony events summary",
      report.summary,
      "",
      "Recent events:",
      format_event_lines(report),
      "",
      "Raw event file: #{report.events_path}"
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @spec record_issue_event(String.t(), map()) :: :ok
  def record_issue_event(cwd, entry) when is_binary(cwd) and is_map(entry) do
    entry = entry |> normalize_entry() |> EventLog.sanitize()

    case issue_identifier(entry) do
      nil ->
        :ok

      issue_identifier ->
        summary_path = path(cwd, issue_identifier)
        summary = read_summary(summary_path, issue_identifier)
        updated = merge_summary(summary, entry)

        with :ok <- File.mkdir_p(Path.dirname(summary_path)),
             {:ok, encoded} <- Jason.encode(updated),
             :ok <- File.write(summary_path, encoded <> "\n") do
          :ok
        else
          _error -> :ok
        end
    end
  end

  defp read_summary(path, issue_identifier) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = summary} -> summary
          _error -> empty_summary(issue_identifier)
        end

      _error ->
        empty_summary(issue_identifier)
    end
  end

  defp empty_summary(issue_identifier) do
    %{
      "schema_version" => @schema_version,
      "issue_identifier" => issue_identifier,
      "event_count" => 0,
      "timeline" => []
    }
  end

  defp merge_summary(summary, entry) do
    details = Map.get(entry, "details", %{})
    timeline = Map.get(summary, "timeline", []) ++ [timeline_item(entry, details)]
    {failure_reason, failure_stage} = next_failure_context(summary, entry, details)

    summary
    |> Map.put("schema_version", @schema_version)
    |> maybe_put("graph_task_id", Map.get(entry, "graph_task_id"))
    |> maybe_put("workspace_path", Map.get(details, "workspace_path"))
    |> maybe_put("branch", Map.get(details, "branch"))
    |> maybe_put("base_branch", Map.get(details, "base_branch"))
    |> maybe_put("pull_request_url", Map.get(details, "pull_request_url"))
    |> Map.put("failure_reason", failure_reason)
    |> Map.put("failure_stage", failure_stage)
    |> Map.put("last_event", Map.get(entry, "event"))
    |> Map.put("last_phase", Map.get(entry, "phase"))
    |> Map.put("last_severity", Map.get(entry, "severity"))
    |> Map.put("updated_at", Map.get(entry, "timestamp"))
    |> Map.put("event_count", length(timeline))
    |> Map.put("timeline", timeline)
  end

  defp timeline_item(entry, details) do
    base = %{
      "timestamp" => Map.get(entry, "timestamp"),
      "event" => Map.get(entry, "event"),
      "phase" => Map.get(entry, "phase"),
      "severity" => Map.get(entry, "severity")
    }

    Enum.reduce(@timeline_keys, base, fn key, acc ->
      maybe_put(acc, key, Map.get(details, key))
    end)
  end

  defp normalize_entry(%{} = entry) do
    entry
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), normalize_value(value)} end)
    |> Map.update("details", %{}, &normalize_value/1)
  end

  defp normalize_value(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> normalize_value()

  defp normalize_value(%{} = map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_value(list) when is_list(list) do
    if Keyword.keyword?(list) do
      Enum.into(list, %{}, fn {key, value} -> {to_string(key), normalize_value(value)} end)
    else
      Enum.map(list, &normalize_value/1)
    end
  end

  defp normalize_value(value), do: value

  defp issue_identifier(entry) do
    Map.get(entry, :issue_identifier) || Map.get(entry, "issue_identifier")
  end

  defp next_failure_context(summary, entry, details) do
    cond do
      failure_cleared?(entry) ->
        {nil, nil}

      present?(Map.get(details, "failure_reason")) ->
        {Map.get(details, "failure_reason"), failure_stage(summary, entry, details)}

      true ->
        {Map.get(summary, "failure_reason"), Map.get(summary, "failure_stage")}
    end
  end

  defp failure_cleared?(entry) do
    event = Map.get(entry, "event", "")
    severity = Map.get(entry, "severity")

    severity != "warning" and MapSet.member?(success_events(), event)
  end

  defp success_events do
    MapSet.new([
      "review_transition_completed",
      "review_completed",
      "recovery_completed",
      "merge_completed",
      "merge_runtime_completed"
    ])
  end

  defp failure_stage(summary, entry, details) do
    Map.get(details, "failure_stage") ||
      Map.get(details, "stage") ||
      preserved_failure_stage(summary, entry) ||
      Map.get(entry, "phase")
  end

  defp preserved_failure_stage(summary, entry) do
    event = Map.get(entry, "event", "")
    phase = Map.get(entry, "phase")

    if phase in ["recovery", "retry"] and String.ends_with?(event, "_started") do
      Map.get(summary, "failure_stage")
    end
  end

  defp present?(value) when value in [nil, ""], do: false
  defp present?(_value), do: true

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp events_path(cwd, nil), do: EventLog.path(cwd)

  defp events_path(cwd, issue_identifier) do
    Path.join([cwd, "tmp", "symphony", "runs", issue_identifier, "events.jsonl"])
  end

  defp report_mode(nil), do: :global
  defp report_mode(_issue_identifier), do: :issue

  defp read_events(path) do
    case File.read(path) do
      {:ok, contents} ->
        events =
          contents
          |> String.split("\n", trim: true)
          |> Enum.flat_map(fn line ->
            case Jason.decode(line) do
              {:ok, %{} = event} -> [event]
              _error -> []
            end
          end)

        {:ok, events}

      {:error, :enoent} ->
        :missing

      {:error, _reason} ->
        :missing
    end
  end

  defp load_summary_file(nil), do: nil

  defp load_summary_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, %{} = summary} -> summary
          _error -> nil
        end

      _error ->
        nil
    end
  end

  defp build_summary(nil, _summary, events, limited_events) do
    total_events = length(events)
    shown_events = length(limited_events)

    case List.last(events) do
      nil ->
        missing_summary(nil)

      latest ->
        "Showing #{shown_events} of #{total_events} recorded Symphony events. " <>
          "Latest event: #{latest_event_sentence(latest, true)}."
    end
  end

  defp build_summary(issue_identifier, nil, events, _limited_events) do
    total_events = length(events)

    case List.last(events) do
      nil ->
        missing_summary(issue_identifier)

      latest ->
        "Issue #{issue_identifier} has #{total_events} recorded events. " <>
          "Latest event: #{latest_event_sentence(latest, false)}."
    end
  end

  defp build_summary(issue_identifier, summary, events, limited_events) do
    total_events = Map.get(summary, "event_count", length(events))
    latest_event = Map.get(summary, "last_event") || latest_event_name(limited_events, events)
    latest_phase = Map.get(summary, "last_phase")
    updated_at = Map.get(summary, "updated_at") || latest_timestamp(limited_events, events)
    failure_reason = Map.get(summary, "failure_reason")
    failure_stage = Map.get(summary, "failure_stage")
    pull_request_url = Map.get(summary, "pull_request_url")

    [
      "Issue #{issue_identifier} has #{total_events} recorded events.",
      " Latest event: #{latest_event_phrase(latest_event, latest_phase, updated_at)}.",
      failure_phrase(failure_reason, failure_stage),
      pull_request_phrase(pull_request_url)
    ]
    |> Enum.join()
  end

  defp missing_summary(nil), do: "No recorded Symphony events were found yet."

  defp missing_summary(issue_identifier) do
    "No recorded Symphony events were found yet for issue #{issue_identifier}."
  end

  defp latest_event_sentence(event, include_issue?) do
    event_name = Map.get(event, "event", "unknown")
    issue_identifier = Map.get(event, "issue_identifier")
    timestamp = Map.get(event, "timestamp")

    event_name
    |> maybe_append_issue(issue_identifier, include_issue?)
    |> maybe_append_timestamp(timestamp)
  end

  defp latest_event_phrase(event, phase, timestamp) do
    event
    |> maybe_append_phase(phase)
    |> maybe_append_timestamp(timestamp)
  end

  defp failure_phrase(nil, _stage), do: ""

  defp failure_phrase(reason, stage) do
    stage_fragment =
      case stage do
        value when value in [nil, ""] -> ""
        value -> " in #{value}"
      end

    " It currently looks stuck#{stage_fragment} because #{reason}."
  end

  defp pull_request_phrase(nil), do: ""
  defp pull_request_phrase(""), do: ""
  defp pull_request_phrase(url), do: " Pull request: #{url}."

  defp latest_event_name([], events),
    do: events |> List.last() |> safe_map_get("event", "unknown")

  defp latest_event_name(limited_events, _events) do
    limited_events |> List.last() |> safe_map_get("event", "unknown")
  end

  defp latest_timestamp([], events), do: events |> List.last() |> safe_map_get("timestamp")

  defp latest_timestamp(limited_events, _events),
    do: limited_events |> List.last() |> safe_map_get("timestamp")

  defp format_event_lines(%{events: []}) do
    ["- none recorded yet"]
  end

  defp format_event_lines(%{events: events, mode: mode}) do
    Enum.map(events, fn event ->
      timestamp = Map.get(event, "timestamp", "unknown time")
      event_name = Map.get(event, "event", "unknown")
      issue_identifier = Map.get(event, "issue_identifier")
      phase = Map.get(event, "phase")
      details = Map.get(event, "details", %{})

      base =
        "- #{timestamp} #{event_name}"
        |> maybe_append_issue(issue_identifier, mode == :global)
        |> maybe_append_phase(phase)

      base <> event_details_suffix(details)
    end)
  end

  defp event_details_suffix(details) do
    cond do
      present?(Map.get(details, "message")) ->
        " - #{Map.get(details, "message")}"

      present?(Map.get(details, "failure_reason")) ->
        " - #{Map.get(details, "failure_reason")}"

      present?(Map.get(details, "pull_request_url")) ->
        " - PR #{Map.get(details, "pull_request_url")}"

      is_map(Map.get(details, "counts_by_status")) ->
        " - #{format_counts(Map.get(details, "counts_by_status"))}"

      present?(Map.get(details, "command")) and not is_nil(Map.get(details, "exit_status")) ->
        " - #{Map.get(details, "command")} (exit #{Map.get(details, "exit_status")})"

      present?(Map.get(details, "outcome")) ->
        " - outcome #{Map.get(details, "outcome")}"

      present?(Map.get(details, "elapsed_ms")) ->
        " - #{Map.get(details, "elapsed_ms")}ms"

      true ->
        ""
    end
  end

  defp format_counts(counts) do
    ready = Map.get(counts, "ready") || Map.get(counts, :ready) || 0
    in_progress = Map.get(counts, "in_progress") || Map.get(counts, :in_progress) || 0
    blocked = Map.get(counts, "blocked") || Map.get(counts, :blocked) || 0
    done = Map.get(counts, "done") || Map.get(counts, :done) || 0
    "ready #{ready}, in_progress #{in_progress}, blocked #{blocked}, done #{done}"
  end

  defp maybe_append_issue(text, issue_identifier, true)
       when is_binary(issue_identifier) and issue_identifier != "" do
    text <> " for #{issue_identifier}"
  end

  defp maybe_append_issue(text, _issue_identifier, _include_issue?), do: text

  defp maybe_append_phase(text, phase) when is_binary(phase) and phase != "",
    do: text <> " [#{phase}]"

  defp maybe_append_phase(text, _phase), do: text

  defp maybe_append_timestamp(text, timestamp) when is_binary(timestamp) and timestamp != "" do
    text <> " at #{timestamp}"
  end

  defp maybe_append_timestamp(text, _timestamp), do: text

  defp safe_map_get(map, key, default \\ nil)
  defp safe_map_get(nil, _key, default), do: default
  defp safe_map_get(map, key, default), do: Map.get(map, key, default)

  defp take_last(events, count) when is_integer(count) and count > 0 do
    events
    |> Enum.reverse()
    |> Enum.take(count)
    |> Enum.reverse()
  end

  defp take_last(_events, _count), do: []

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(value), do: to_string(value)
end
