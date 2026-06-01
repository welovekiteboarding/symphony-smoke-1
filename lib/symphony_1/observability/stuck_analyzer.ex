defmodule Symphony1.Observability.StuckAnalyzer do
  @moduledoc """
  Classifies evidence-backed unattended-run stalls from graph summary state,
  already-known Linear state, and repo-local recorder artifacts.
  """

  @spec analyze(map()) :: :ok | {:stuck, map()}
  def analyze(snapshot) when is_map(snapshot) do
    summary = Map.fetch!(snapshot, :graph_summary)
    materialized_count = Map.get(snapshot, :materialized_count, 0)
    run_result_count = Map.get(snapshot, :run_result_count, 0)
    review_result_count = Map.get(snapshot, :review_result_count, 0)
    merge_result_count = Map.get(snapshot, :merge_result_count, 0)

    if produced_progress?(
         materialized_count,
         run_result_count,
         review_result_count,
         merge_result_count
       ) do
      :ok
    else
      mapped_entries = mapped_entries(summary)
      ready_materialized = Enum.filter(mapped_entries, &(&1.graph_status == "ready"))
      in_progress = Enum.filter(mapped_entries, &(&1.graph_status == "in_progress"))
      linear_states = Map.get(snapshot, :linear_states, %{})
      review_issue_ids = review_issue_ids(Map.get(snapshot, :review_files, []))
      open_prs = open_pr_map(Map.get(snapshot, :open_prs, []))

      cond do
        match = find_linear_rework_mismatch(mapped_entries, linear_states) ->
          {:stuck, match}

        match =
            find_human_review_without_artifact(mapped_entries, linear_states, review_issue_ids) ->
          {:stuck, match}

        match = find_open_pr_without_graph_done(mapped_entries, open_prs) ->
          {:stuck, match}

        match = find_ready_but_already_materialized(ready_materialized) ->
          {:stuck, match}

        ready_materialized != [] or in_progress != [] ->
          {:stuck,
           %{
             reason: :mapped_work_without_new_results,
             ready_materialized: plain_entries(ready_materialized),
             in_progress: plain_entries(in_progress)
           }}

        true ->
          :ok
      end
    end
  end

  defp produced_progress?(
         materialized_count,
         run_result_count,
         review_result_count,
         merge_result_count
       ) do
    materialized_count > 0 or run_result_count > 0 or review_result_count > 0 or
      merge_result_count > 0
  end

  defp find_linear_rework_mismatch(entries, linear_states) do
    Enum.find_value(entries, fn entry ->
      if Map.get(linear_states, entry.linear) == "Rework" and entry.graph_status != "rework" do
        %{
          reason: :linear_rework_without_graph_rework,
          issue_identifier: entry.linear,
          linear_state: "Rework",
          task_id: entry.id,
          task_title: entry.title,
          graph_status: entry.graph_status
        }
      end
    end)
  end

  defp find_human_review_without_artifact(entries, linear_states, review_issue_ids) do
    Enum.find_value(entries, fn entry ->
      if Map.get(linear_states, entry.linear) == "Human Review" and
           not MapSet.member?(review_issue_ids, entry.linear) do
        %{
          reason: :human_review_without_review_artifact,
          issue_identifier: entry.linear,
          expected_review_file: review_file(entry.linear),
          task_id: entry.id,
          task_title: entry.title,
          graph_status: entry.graph_status
        }
      end
    end)
  end

  defp find_open_pr_without_graph_done(entries, open_prs) do
    Enum.find_value(entries, fn entry ->
      case Map.get(open_prs, entry.linear) do
        %{url: url} when entry.graph_status != "done" and is_binary(url) and url != "" ->
          %{
            reason: :open_pr_without_graph_done,
            issue_identifier: entry.linear,
            pull_request_url: url,
            task_id: entry.id,
            task_title: entry.title,
            graph_status: entry.graph_status
          }

        _other ->
          nil
      end
    end)
  end

  defp find_ready_but_already_materialized(ready_materialized) do
    case ready_materialized do
      [entry | _] ->
        %{
          reason: :graph_ready_but_already_materialized,
          issue_identifier: entry.linear,
          task_id: entry.id,
          task_title: entry.title,
          graph_status: entry.graph_status
        }

      [] ->
        nil
    end
  end

  defp mapped_entries(summary) do
    [
      {"ready", Map.get(summary, :ready, [])},
      {"in_progress", Map.get(summary, :in_progress, [])},
      {"blocked", Map.get(summary, :blocked, [])},
      {"rework", Map.get(summary, :rework, [])},
      {"done", Map.get(summary, :done, [])}
    ]
    |> Enum.flat_map(fn {graph_status, entries} ->
      Enum.flat_map(entries, fn entry ->
        case Map.get(entry, :linear) do
          nil ->
            []

          linear ->
            [
              %{
                id: Map.fetch!(entry, :id),
                title: Map.fetch!(entry, :title),
                linear: linear,
                graph_status: graph_status
              }
            ]
        end
      end)
    end)
  end

  defp plain_entries(entries) do
    Enum.map(entries, fn entry ->
      Map.take(entry, [:id, :title, :linear])
    end)
  end

  defp review_issue_ids(files) do
    files
    |> Enum.map(&review_issue_id/1)
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp review_issue_id(file) when is_binary(file) do
    file
    |> Path.basename()
    |> Path.rootname()
    |> case do
      "" -> nil
      issue_identifier -> issue_identifier
    end
  end

  defp review_issue_id(_file), do: nil

  defp open_pr_map(open_prs) do
    Enum.reduce(open_prs, %{}, fn
      %{issue_identifier: issue_identifier} = open_pr, acc when is_binary(issue_identifier) ->
        Map.put(acc, issue_identifier, open_pr)

      %{"issue_identifier" => issue_identifier} = open_pr, acc when is_binary(issue_identifier) ->
        Map.put(acc, issue_identifier, normalize_open_pr(open_pr))

      _other, acc ->
        acc
    end)
  end

  defp normalize_open_pr(%{} = open_pr) do
    %{
      issue_identifier:
        Map.get(open_pr, :issue_identifier) || Map.get(open_pr, "issue_identifier"),
      url: Map.get(open_pr, :url) || Map.get(open_pr, "url")
    }
  end

  defp review_file(issue_identifier),
    do: Path.join(["tmp", "reviews", "#{issue_identifier}.json"])
end
