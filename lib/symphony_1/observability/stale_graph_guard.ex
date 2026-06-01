defmodule Symphony1.Observability.StaleGraphGuard do
  @moduledoc """
  Blocks materialization when the current graph has regressed behind durable
  recorder evidence for the same graph path.
  """

  alias Symphony1.Observability.EventLog
  alias Symphony1.Planning.{Graph, Materializer}

  @type regression :: %{
          task_id: String.t(),
          prior_status: String.t(),
          prior_linear_issue_identifier: String.t() | nil,
          current_status: String.t()
        }

  @type stale_graph_error :: %{
          graph_path: String.t(),
          regressions: [regression()],
          recovery_action: String.t()
        }

  @type latest_evidence :: %{
          tasks: [map()],
          recovery_action: String.t()
        }

  @spec repo_root_for_graph(String.t()) :: String.t()
  def repo_root_for_graph(graph_path) when is_binary(graph_path) do
    expanded_graph_path = Path.expand(graph_path)
    graph_dir = Path.dirname(expanded_graph_path)

    case planning_dir(graph_dir) do
      nil -> graph_dir
      dir -> Path.dirname(dir)
    end
  end

  @spec check(String.t(), String.t(), Graph.t()) :: :ok | {:error, stale_graph_error()}
  def check(cwd, graph_path, %Graph{} = graph) when is_binary(cwd) and is_binary(graph_path) do
    case latest_graph_evidence(cwd, graph_path) do
      :none ->
        :ok

      {:ok, evidence} ->
        regressions = detect_regressions(evidence.tasks, graph)

        if regressions == [] do
          :ok
        else
          {:error,
           %{
             graph_path: graph_path,
             regressions: regressions,
             recovery_action: evidence.recovery_action
           }}
        end
    end
  end

  @spec error_message(stale_graph_error()) :: String.t()
  def error_message(%{graph_path: graph_path, regressions: regressions, recovery_action: action}) do
    details =
      regressions
      |> Enum.map(fn regression ->
        issue_identifier =
          case regression.prior_linear_issue_identifier do
            nil -> "unknown prior Linear issue"
            value -> "prior Linear issue #{value}"
          end

        "task #{regression.task_id} was previously #{regression.prior_status} " <>
          "(#{issue_identifier}) but the current status #{regression.current_status} " <>
          "lost that recorded state"
      end)
      |> Enum.join("; ")

    "stale graph regression detected for #{graph_path}: #{details}. " <>
      "Recovery action: #{action}"
  end

  @spec latest_graph_evidence(String.t(), String.t()) :: :none | {:ok, latest_evidence()}
  defp latest_graph_evidence(cwd, graph_path) do
    event_log_path = EventLog.path(cwd)
    expanded_graph_path = Materializer.canonical_graph_path(graph_path)

    case File.read(event_log_path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.reverse()
        |> Enum.find_value(:none, fn line ->
          with {:ok, %{"details" => details}} <- Jason.decode(line),
               true <- same_graph_path?(details["graph_path"], expanded_graph_path),
               %{"tasks" => tasks} <- details["graph_state"],
               true <- is_list(tasks) and tasks != [] do
            {:ok,
             %{
               tasks: tasks,
               recovery_action: recovery_action(details, graph_path)
             }}
          else
            _other -> nil
          end
        end)

      {:error, :enoent} ->
        :none

      {:error, _reason} ->
        :none
    end
  end

  defp same_graph_path?(recorded_graph_path, expanded_graph_path)
       when is_binary(recorded_graph_path) do
    Materializer.canonical_graph_path(recorded_graph_path) == expanded_graph_path
  end

  defp same_graph_path?(_recorded_graph_path, _expanded_graph_path), do: false

  defp detect_regressions(evidence_tasks, %Graph{} = current_graph) do
    current_tasks = Map.new(current_graph.tasks, &{&1.id, &1})

    Enum.flat_map(evidence_tasks, fn evidence_task ->
      case regression_for_task(evidence_task, current_tasks) do
        nil -> []
        regression -> [regression]
      end
    end)
  end

  defp regression_for_task(
         %{
           "task_id" => task_id,
           "status" => prior_status,
           "materialized" => prior_materialized,
           "linear_issue_id" => prior_linear_issue_id,
           "linear_issue_identifier" => prior_linear_issue_identifier
         },
         current_tasks
       ) do
    current_task = Map.get(current_tasks, task_id)
    current_status = if current_task, do: current_task.status, else: "missing"

    lost_done_status? = prior_status == "done" and current_status != "done"

    lost_mapping? =
      prior_materialized == true and
        not current_issue_identity_recorded?(
          current_task,
          prior_linear_issue_id,
          prior_linear_issue_identifier
        )

    if lost_done_status? or lost_mapping? do
      %{
        task_id: task_id,
        prior_status: prior_status,
        prior_linear_issue_identifier: prior_linear_issue_identifier,
        current_status: current_status
      }
    end
  end

  defp regression_for_task(_evidence_task, _current_tasks), do: nil

  defp current_issue_identity_recorded?(
         nil,
         _prior_linear_issue_id,
         _prior_linear_issue_identifier
       ),
       do: false

  defp current_issue_identity_recorded?(
         current_task,
         prior_linear_issue_id,
         prior_linear_issue_identifier
       ) do
    current_materialization_matches?(
      current_task,
      prior_linear_issue_id,
      prior_linear_issue_identifier
    ) or
      current_last_failure_matches?(
        current_task,
        prior_linear_issue_id,
        prior_linear_issue_identifier
      )
  end

  defp current_materialization_matches?(
         current_task,
         prior_linear_issue_id,
         prior_linear_issue_identifier
       ) do
    materialization = current_task.materialization || %Graph.Materialization{}

    materialization.materialized == true and
      ((is_binary(prior_linear_issue_id) and prior_linear_issue_id != "" and
          materialization.linear_issue_id == prior_linear_issue_id) or
         (is_binary(prior_linear_issue_identifier) and prior_linear_issue_identifier != "" and
            materialization.linear_issue_identifier == prior_linear_issue_identifier))
  end

  defp current_last_failure_matches?(
         current_task,
         prior_linear_issue_id,
         prior_linear_issue_identifier
       ) do
    case current_task.last_failure do
      %Graph.LastFailure{} = last_failure ->
        (is_binary(prior_linear_issue_id) and prior_linear_issue_id != "" and
           last_failure.linear_issue_id == prior_linear_issue_id) or
          (is_binary(prior_linear_issue_identifier) and
             prior_linear_issue_identifier != "" and
             last_failure.linear_issue_identifier == prior_linear_issue_identifier)

      _other ->
        false
    end
  end

  defp recovery_action(details, graph_path) do
    case get_in(details, ["persistence_failure", "recovery_snapshot_path"]) do
      snapshot_path when is_binary(snapshot_path) and snapshot_path != "" ->
        "run mix symphony.plan_materialize_recover --snapshot #{snapshot_path} " <>
          "to reapply the recorded Linear mappings, or restore the graph file at #{graph_path} " <>
          "from the latest durable checkpoint before materializing again"

      _other ->
        generic_recovery_action(graph_path)
    end
  end

  defp generic_recovery_action(graph_path) do
    "restore the graph file at #{graph_path} from the latest durable checkpoint " <>
      "or reapply the recorded Linear mappings before materializing again"
  end

  defp planning_dir(dir) do
    parent = Path.dirname(dir)

    cond do
      Path.basename(dir) == "planning" -> dir
      parent == dir -> nil
      true -> planning_dir(parent)
    end
  end
end
