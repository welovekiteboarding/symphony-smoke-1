defmodule Symphony1.Core.QueueLauncher do
  alias Symphony1.Core.RunCoordinator
  alias Symphony1.Observability.Recorder
  alias Symphony1.Planning.Graph

  @spec launch(map()) ::
          {:ok, Task.t(), %{issue_identifier: String.t()}} | :none | {:error, term()}
  def launch(attrs) do
    attrs = RunCoordinator.normalize_run_attrs(attrs)
    progress_reporter = Map.get(attrs, :progress_reporter, fn _message -> :ok end)

    with {:ok, run} <- RunCoordinator.run_issue(attrs) do
      progress_reporter.("Claimed #{run.issue.identifier} -> #{run.issue.state}")

      record_queue_launch(attrs, run)

      {:ok, Task.async(fn -> RunCoordinator.finish_claimed_issue(run, attrs) end),
       %{issue: run.issue, issue_identifier: run.issue.identifier}}
    else
      :none ->
        :none

      {:error, {:workspace_creation_failed, issue, workspace_path, reason}} ->
        RunCoordinator.recover_workspace_creation_failure(issue, attrs, workspace_path, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_queue_launch(attrs, run) do
    case Map.get(attrs, :observability_root) || Map.get(attrs, :source_repo) do
      nil ->
        :ok

      root ->
        Recorder.record(root, "queue_launch_dispatched",
          issue_identifier: run.issue.identifier,
          graph_task_id: graph_task_id(run.issue, attrs),
          phase: "queue",
          details: %{
            workspace_path: run.workspace,
            branch: Map.get(attrs, :branch, "issue-" <> String.downcase(run.issue.identifier)),
            base_branch: Map.get(attrs, :base_branch)
          }
        )
    end
  end

  defp graph_task_id(issue, %{graph: graph}) do
    case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
      {:ok, task} -> task.id
      :none -> nil
    end
  end

  defp graph_task_id(_issue, _attrs), do: nil
end
