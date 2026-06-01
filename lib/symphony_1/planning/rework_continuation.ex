defmodule Symphony1.Planning.ReworkContinuation do
  @moduledoc """
  Pure decision logic for continuing review rework on the same issue.

  Continuation is intentionally stricter than clean retry: the graph task must
  still be in `rework` and must still point at an existing Linear issue.
  """

  alias Symphony1.Planning.Graph

  defmodule Decision do
    @moduledoc false

    defstruct [
      :task_id,
      :issue_id,
      :issue_identifier,
      :branch,
      :reason,
      :stage,
      :category
    ]
  end

  @spec classify(Graph.t(), String.t()) :: {:ok, Decision.t()} | {:error, term()}
  def classify(%Graph{} = graph, task_id) do
    case Enum.find(graph.tasks, &(&1.id == task_id)) do
      nil ->
        {:error, {:task_not_found, task_id}}

      %Graph.Task{status: status} when status != "rework" ->
        {:error, {:not_rework, task_id, status}}

      %Graph.Task{} = task ->
        classify_rework_task(task)
    end
  end

  defp classify_rework_task(%Graph.Task{} = task) do
    materialization = task.materialization || %Graph.Materialization{}

    cond do
      materialization.linear_issue_id in [nil, ""] ->
        {:error, {:not_continuable, task.id, :missing_materialization}}

      materialization.linear_issue_identifier in [nil, ""] ->
        {:error, {:not_continuable, task.id, :missing_materialization}}

      true ->
        failure = task.last_failure || %Graph.LastFailure{}

        {:ok,
         %Decision{
           task_id: task.id,
           issue_id: materialization.linear_issue_id,
           issue_identifier: materialization.linear_issue_identifier,
           branch: branch_name(materialization.linear_issue_identifier),
           reason: failure.reason,
           stage: failure.stage,
           category: failure.category
         }}
    end
  end

  defp branch_name(issue_identifier) do
    "issue-" <> String.downcase(issue_identifier)
  end
end
