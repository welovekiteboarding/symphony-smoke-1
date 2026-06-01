defmodule Mix.Tasks.Symphony.PlanRetry do
  use Mix.Task

  alias Symphony1.Core.Linear
  alias Symphony1.Planning.{Graph, ReworkContinuation}
  alias Symphony1.RuntimeConfig

  @shortdoc "Retry a rework graph task — clears mapping, preserves failure history"

  @impl true
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        strict: [continue: :boolean, graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_retry TASK_ID --graph PATH")
        path -> path
      end

    task_id =
      case positional do
        [id | _] -> id
        [] -> Mix.raise("usage: mix symphony.plan_retry TASK_ID --graph PATH")
      end

    if Keyword.get(opts, :continue, false) do
      continue_task(graph_path, task_id, Keyword.get(opts, :team_key))
    else
      retry_task(graph_path, task_id)
    end
  end

  defp retry_task(graph_path, task_id) do
    with {:ok, graph} <- Graph.load(graph_path),
         {:ok, updated} <- Graph.retry_task(graph, task_id),
         :ok <- Graph.write(updated, graph_path) do
      Mix.shell().info("Retried #{task_id} — moved to pending, failure history preserved")
    else
      {:error, {:task_not_found, id}} ->
        Mix.raise("task #{id} not found in graph")

      {:error, {:not_rework, id, status}} ->
        Mix.raise("task #{id} is not in rework (current: #{status})")

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end

  defp continue_task(_graph_path, _task_id, nil) do
    Mix.raise("usage: mix symphony.plan_retry TASK_ID --graph PATH --continue --team-key KEY")
  end

  defp continue_task(graph_path, task_id, team_key) do
    with {:ok, graph} <- Graph.load(graph_path),
         {:ok, decision} <- ReworkContinuation.classify(graph, task_id),
         {:ok, _issue} <- transition_rework_issue_to_todo(decision, team_key),
         {:ok, updated} <- Graph.continue_rework_task(graph, task_id),
         :ok <- Graph.write(updated, graph_path) do
      Mix.shell().info(
        "Continued #{task_id} — preserved #{decision.issue_identifier} and moved it to Todo"
      )
    else
      {:error, {:task_not_found, id}} ->
        Mix.raise("task #{id} not found in graph")

      {:error, {:not_rework, id, status}} ->
        Mix.raise("task #{id} is not in rework (current: #{status})")

      {:error, reason} ->
        Mix.raise("failed to continue #{task_id}: #{inspect(reason)}")
    end
  end

  defp transition_rework_issue_to_todo(decision, team_key) do
    config_loader =
      Application.get_env(
        :symphony_1,
        :plan_retry_linear_config_loader,
        &RuntimeConfig.linear_config!/1
      )

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

    transitioner.(issue, "Todo", config_loader.(team_key))
  end

  defp default_rework_continuation_transitioner(issue, target_state, linear_config) do
    Linear.transition_issue(issue, target_state, linear_config)
  end
end
