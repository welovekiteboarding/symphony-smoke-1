defmodule Symphony1.Observability.StuckExplanation do
  @moduledoc """
  Produces plain explanations when an operator tick makes no visible progress.
  """

  alias Symphony1.Observability.StuckAnalyzer

  @spec explain(map(), keyword()) :: :ok | {:stuck, map()}
  def explain(summary, opts) do
    materialized_count = Keyword.fetch!(opts, :materialized_count)
    run_result_count = Keyword.fetch!(opts, :run_result_count)
    review_result_count = Keyword.get(opts, :review_result_count, 0)
    merge_result_count = Keyword.get(opts, :merge_result_count, 0)

    snapshot = %{
      graph_summary: summary,
      materialized_count: materialized_count,
      run_result_count: run_result_count,
      review_result_count: review_result_count,
      merge_result_count: merge_result_count,
      review_files: local_review_files(opts),
      open_prs: local_open_prs(opts),
      linear_states: Keyword.get(opts, :linear_states, %{})
    }

    case StuckAnalyzer.analyze(snapshot) do
      {:stuck, analysis} ->
        {:stuck,
         analysis
         |> build_explanation(opts)
         |> Map.merge(%{
           materialized_count: materialized_count,
           run_result_count: run_result_count,
           review_result_count: review_result_count,
           merge_result_count: merge_result_count
         })}

      :ok ->
        :ok
    end
  end

  defp build_explanation(%{reason: :mapped_work_without_new_results} = analysis, opts) do
    ready_materialized = Map.fetch!(analysis, :ready_materialized)
    in_progress = Map.fetch!(analysis, :in_progress)

    %{
      reason: :mapped_work_without_new_results,
      message:
        "No worker result was produced this tick, and no review or merge result was produced " <>
          "either, but the graph still has existing mapped work. Symphony is likely waiting on " <>
          "the current issue, PR, or review lane.",
      evidence: %{
        ready_materialized: ready_materialized,
        in_progress: in_progress
      },
      suggested_next_command: events_command(opts),
      ready_materialized: ready_materialized,
      in_progress: in_progress
    }
  end

  defp build_explanation(%{reason: :human_review_without_review_artifact} = analysis, opts) do
    issue_identifier = Map.fetch!(analysis, :issue_identifier)
    task_id = Map.fetch!(analysis, :task_id)
    task_title = Map.fetch!(analysis, :task_title)
    graph_status = Map.fetch!(analysis, :graph_status)
    expected_review_file = Map.fetch!(analysis, :expected_review_file)

    %{
      reason: :human_review_without_review_artifact,
      message: "#{issue_identifier} is in Human Review, but no review JSON exists locally.",
      evidence: %{
        issue_identifier: issue_identifier,
        task_id: task_id,
        task_title: task_title,
        graph_status: graph_status,
        expected_review_file: expected_review_file
      },
      suggested_next_command: review_command(opts)
    }
  end

  defp build_explanation(%{reason: :open_pr_without_graph_done} = analysis, opts) do
    issue_identifier = Map.fetch!(analysis, :issue_identifier)
    task_id = Map.fetch!(analysis, :task_id)
    task_title = Map.fetch!(analysis, :task_title)
    graph_status = Map.fetch!(analysis, :graph_status)
    pull_request_url = Map.fetch!(analysis, :pull_request_url)

    %{
      reason: :open_pr_without_graph_done,
      message:
        "#{issue_identifier} already has a recorded pull request, but graph task #{task_id} " <>
          "is still #{graph_status}.",
      evidence: %{
        issue_identifier: issue_identifier,
        task_id: task_id,
        task_title: task_title,
        graph_status: graph_status,
        pull_request_url: pull_request_url
      },
      suggested_next_command: issue_events_command(opts, issue_identifier)
    }
  end

  defp build_explanation(%{reason: :linear_rework_without_graph_rework} = analysis, opts) do
    issue_identifier = Map.fetch!(analysis, :issue_identifier)
    task_id = Map.fetch!(analysis, :task_id)
    task_title = Map.fetch!(analysis, :task_title)
    graph_status = Map.fetch!(analysis, :graph_status)
    linear_state = Map.fetch!(analysis, :linear_state)

    %{
      reason: :linear_rework_without_graph_rework,
      message:
        "#{issue_identifier} is already #{linear_state} in Linear, but graph task #{task_id} " <>
          "is still #{graph_status}.",
      evidence: %{
        issue_identifier: issue_identifier,
        task_id: task_id,
        task_title: task_title,
        graph_status: graph_status,
        linear_state: linear_state
      },
      suggested_next_command: plan_sync_command(opts)
    }
  end

  defp build_explanation(%{reason: :graph_ready_but_already_materialized} = analysis, opts) do
    issue_identifier = Map.fetch!(analysis, :issue_identifier)
    task_id = Map.fetch!(analysis, :task_id)
    task_title = Map.fetch!(analysis, :task_title)

    %{
      reason: :graph_ready_but_already_materialized,
      message:
        "Graph task #{task_id} is still listed as ready even though it is already materialized " <>
          "to #{issue_identifier}.",
      evidence: %{
        issue_identifier: issue_identifier,
        task_id: task_id,
        task_title: task_title,
        graph_status: "ready"
      },
      suggested_next_command: plan_sync_command(opts)
    }
  end

  defp local_review_files(opts) do
    case Keyword.fetch(opts, :review_files) do
      {:ok, files} ->
        files

      :error ->
        case Keyword.get(opts, :cwd) do
          nil -> []
          cwd -> read_review_files(cwd)
        end
    end
  end

  defp local_open_prs(opts) do
    case Keyword.fetch(opts, :open_prs) do
      {:ok, open_prs} ->
        open_prs

      :error ->
        case Keyword.get(opts, :cwd) do
          nil -> []
          cwd -> read_open_prs(cwd)
        end
    end
  end

  defp read_review_files(cwd) do
    review_dir = Path.join([cwd, "tmp", "reviews"])

    case File.ls(review_dir) do
      {:ok, files} -> Enum.filter(files, &String.ends_with?(&1, ".json"))
      {:error, _reason} -> []
    end
  end

  defp read_open_prs(cwd) do
    runs_dir = Path.join([cwd, "tmp", "symphony", "runs"])

    case File.ls(runs_dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn issue_identifier ->
          summary_path = Path.join([runs_dir, issue_identifier, "summary.json"])

          case File.read(summary_path) do
            {:ok, contents} ->
              case Jason.decode(contents) do
                {:ok, %{"pull_request_url" => url} = summary}
                when is_binary(url) and url != "" ->
                  if locally_open_pr_summary?(summary) do
                    [%{issue_identifier: issue_identifier, url: url}]
                  else
                    []
                  end

                _other ->
                  []
              end

            {:error, _reason} ->
              []
          end
        end)

      {:error, _reason} ->
        []
    end
  end

  defp locally_open_pr_summary?(%{"pull_request_state" => state})
       when state in ["closed", "merged"] do
    false
  end

  defp locally_open_pr_summary?(%{"last_event" => event})
       when event in ["merge_completed", "merge_runtime_completed"] do
    false
  end

  defp locally_open_pr_summary?(_summary), do: true

  defp events_command(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> "mix symphony.events --last 20"
      cwd -> "mix symphony.events --cwd #{cwd} --last 20"
    end
  end

  defp issue_events_command(opts, issue_identifier) do
    case Keyword.get(opts, :cwd) do
      nil -> "mix symphony.events --issue #{issue_identifier} --last 20"
      cwd -> "mix symphony.events --cwd #{cwd} --issue #{issue_identifier} --last 20"
    end
  end

  defp review_command(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> "mix symphony.review --once"
      cwd -> "mix symphony.review --once --cwd #{cwd}"
    end
  end

  defp plan_sync_command(opts) do
    graph_path = Keyword.get(opts, :graph_path)
    team_key = Keyword.get(opts, :team_key)

    if is_binary(graph_path) and graph_path != "" and is_binary(team_key) and team_key != "" do
      "mix symphony.plan_sync --graph #{graph_path} --team-key #{team_key}"
    else
      events_command(opts)
    end
  end
end
