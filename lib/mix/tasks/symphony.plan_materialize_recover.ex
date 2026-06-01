defmodule Mix.Tasks.Symphony.PlanMaterializeRecover do
  use Mix.Task

  alias Symphony1.Planning.{Graph, Materializer}

  @shortdoc "Recover graph materialization mappings from a plan_materialize snapshot"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [snapshot: :string]
      )

    snapshot_path =
      case Keyword.get(opts, :snapshot) do
        nil -> Mix.raise("usage: mix symphony.plan_materialize_recover --snapshot PATH")
        path -> path
      end

    graph_writer =
      Application.get_env(
        :symphony_1,
        :plan_materialize_recovery_graph_writer,
        &Graph.write/2
      )

    snapshot = load_snapshot!(snapshot_path)
    graph_path = fetch_snapshot_key!(snapshot, "graph_path")
    materialized = Map.get(snapshot, "materialized", [])

    graph =
      case Graph.load(graph_path) do
        {:ok, graph} -> graph
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    recovered_graph =
      Enum.reduce(materialized, graph, fn entry, acc ->
        task_id = fetch_snapshot_key!(entry, "task_id")
        linear_issue_id = fetch_snapshot_key!(entry, "linear_issue_id")
        linear_issue_identifier = fetch_snapshot_key!(entry, "linear_issue_identifier")

        case Graph.update_task(acc, task_id, %{
               status: "in_progress",
               materialization: %{
                 materialized: true,
                 linear_issue_id: linear_issue_id,
                 linear_issue_identifier: linear_issue_identifier
               }
             }) do
          {:ok, updated_graph} ->
            updated_graph

          {:error, reason} ->
            Mix.raise("failed to recover graph task #{task_id}: #{inspect(reason)}")
        end
      end)

    case graph_writer.(recovered_graph, graph_path) do
      :ok ->
        maybe_retire_snapshot(snapshot_path)

        Mix.shell().info(
          "Recovered #{length(materialized)} materialized task(s) into #{graph_path}"
        )

      {:error, reason} ->
        Mix.raise("failed to persist recovered graph: #{inspect(reason)}")
    end
  end

  defp load_snapshot!(snapshot_path) do
    case Materializer.load_recovery_snapshot(snapshot_path) do
      {:ok, snapshot} ->
        snapshot

      {:error, {:recovery_snapshot_read_failed, ^snapshot_path, :enoent}} ->
        Mix.raise("recovery snapshot not found: #{snapshot_path}")

      {:error, {:recovery_snapshot_read_failed, ^snapshot_path, reason}} ->
        Mix.raise("failed to read recovery snapshot: #{inspect(reason)}")

      {:error, {:invalid_recovery_snapshot, ^snapshot_path, {:decode_failed, reason}}} ->
        Mix.raise("failed to decode recovery snapshot: #{inspect(reason)}")

      {:error, {:invalid_recovery_snapshot, ^snapshot_path, :missing_graph_path}} ->
        Mix.raise("recovery snapshot is missing graph_path")

      {:error, {:invalid_recovery_snapshot, ^snapshot_path, {:missing_snapshot_key, key}}} ->
        Mix.raise("recovery snapshot is missing #{key}")

      {:error, {:invalid_recovery_snapshot, ^snapshot_path, reason}} ->
        Mix.raise("invalid recovery snapshot: #{inspect(reason)}")
    end
  end

  defp fetch_snapshot_key!(map, key) do
    case Map.get(map, key) do
      nil -> Mix.raise("recovery snapshot is missing #{key}")
      value -> value
    end
  end

  defp maybe_retire_snapshot(snapshot_path) do
    case File.rm(snapshot_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.shell().info(
          "Recovered graph state but could not retire recovery snapshot #{snapshot_path}: #{inspect(reason)}"
        )
    end
  end
end
