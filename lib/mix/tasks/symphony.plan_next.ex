defmodule Mix.Tasks.Symphony.PlanNext do
  use Mix.Task

  alias Symphony1.Observability.StaleGraphGuard
  alias Symphony1.Planning.{Feedback, Graph, Materializer, Status}
  alias Symphony1.RuntimeConfig

  @shortdoc "Sync outcomes, show status, materialize the next ready wave"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_next --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_next --graph PATH --team-key KEY")
        key -> key
      end

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} ->
          config

        {:error, :missing_linear_api_key} ->
          Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    issue_fetcher = Application.get_env(:symphony_1, :plan_sync_issue_fetcher)
    issue_creator = Application.get_env(:symphony_1, :plan_materializer_issue_creator)

    graph_writer =
      Application.get_env(:symphony_1, :plan_materializer_graph_writer, &Graph.persist/2)

    recovery_snapshot_writer =
      Application.get_env(
        :symphony_1,
        :plan_materializer_recovery_snapshot_writer,
        &Materializer.default_recovery_snapshot_writer/1
      )

    sync_opts = if issue_fetcher, do: [issue_fetcher: issue_fetcher], else: []

    mat_opts =
      if issue_creator,
        do: [
          issue_creator: issue_creator,
          graph_writer: graph_writer,
          recovery_snapshot_writer: recovery_snapshot_writer,
          graph_path: graph_path
        ],
        else: [
          graph_writer: graph_writer,
          recovery_snapshot_writer: recovery_snapshot_writer,
          graph_path: graph_path
        ]

    # Step 1: Load graph
    graph =
      case Graph.load(graph_path) do
        {:ok, g} -> g
        {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
      end

    # Step 2: Sync
    graph =
      case Feedback.sync(graph, linear_config, sync_opts) do
        {:ok, result} ->
          if result.updated != [] do
            :ok = Graph.write(result.graph, graph_path)
            Mix.shell().info("Synced #{length(result.updated)} task(s)")
          end

          result.graph

        {:error, reason} ->
          Mix.raise("sync failed: #{inspect(reason)}")
      end

    # Step 3: Status
    summary = Status.summarize(graph)
    Mix.shell().info(Status.format(summary))

    # Step 4: Materialize (only if there are ready tasks)
    if summary.ready != [] do
      maybe_raise_on_stale_graph_regression!(graph_path, graph)

      case Materializer.materialize_and_persist(graph, linear_config, graph_path, mat_opts) do
        {:ok, result} ->
          Mix.shell().info("Materialized #{length(result.materialized)} task(s)")

          invalid_tasks = Map.get(result, :invalid_tasks, [])

          if invalid_tasks != [] do
            Mix.shell().info("Invalid ready tasks: #{length(invalid_tasks)}")
          end

        {:error, error} ->
          if error.materialized != [] do
            Mix.shell().info(
              "Partial: materialized #{length(error.materialized)} task(s) before failure"
            )
          end

          Mix.raise(Materializer.materialization_error_message(error))
      end
    else
      Mix.shell().info("No ready tasks to materialize")
    end
  end

  defp maybe_raise_on_stale_graph_regression!(graph_path, %Graph{} = graph) do
    case StaleGraphGuard.check(StaleGraphGuard.repo_root_for_graph(graph_path), graph_path, graph) do
      :ok -> :ok
      {:error, error} -> Mix.raise(StaleGraphGuard.error_message(error))
    end
  end
end
