defmodule Mix.Tasks.Symphony.PlanMaterialize do
  use Mix.Task

  alias Symphony1.Observability.StaleGraphGuard
  alias Symphony1.Planning.{Graph, Materializer}
  alias Symphony1.RuntimeConfig

  @shortdoc "Materialize the ready batch from a planning graph into Linear"

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [graph: :string, team_key: :string]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.plan_materialize --graph PATH --team-key KEY")
        path -> path
      end

    team_key =
      case Keyword.get(opts, :team_key) do
        nil -> Mix.raise("usage: mix symphony.plan_materialize --graph PATH --team-key KEY")
        key -> key
      end

    issue_creator =
      Application.get_env(
        :symphony_1,
        :plan_materializer_issue_creator,
        &default_issue_creator/2
      )

    graph_writer =
      Application.get_env(
        :symphony_1,
        :plan_materializer_graph_writer,
        &Graph.persist/2
      )

    recovery_snapshot_writer =
      Application.get_env(
        :symphony_1,
        :plan_materializer_recovery_snapshot_writer,
        &Materializer.default_recovery_snapshot_writer/1
      )

    linear_config =
      case RuntimeConfig.linear_config(team_key) do
        {:ok, config} ->
          config

        {:error, :missing_linear_api_key} ->
          Mix.raise(RuntimeConfig.missing_linear_api_key_message())
      end

    case Graph.load(graph_path) do
      {:ok, graph} ->
        if Graph.ready_tasks(graph) != [] do
          maybe_raise_on_stale_graph_regression!(graph_path, graph)
        end

        case Materializer.materialize_and_persist(
               graph,
               linear_config,
               graph_path,
               issue_creator: issue_creator,
               graph_writer: graph_writer,
               recovery_snapshot_writer: recovery_snapshot_writer
             ) do
          {:ok, result} ->
            Mix.shell().info(
              "Materialized #{length(result.materialized)} task(s), skipped #{length(result.skipped)}"
            )

            invalid_tasks = Map.get(result, :invalid_tasks, [])

            if invalid_tasks != [] do
              Mix.shell().info("Invalid ready tasks: #{length(invalid_tasks)}")
            end

          {:error, %{persistence_failure: _persistence_failure} = error} ->
            if error.materialized != [] do
              Mix.shell().info(
                "Partial: materialized #{length(error.materialized)} task(s) before failure"
              )
            end

            Mix.raise(Materializer.materialization_error_message(error))

          {:error, error} ->
            if error.materialized != [] do
              Mix.shell().info(
                "Partial: materialized #{length(error.materialized)} task(s) before failure"
              )
            end

            Mix.raise(Materializer.materialization_error_message(error))
        end

      {:error, reason} ->
        Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end

  defp default_issue_creator(config, attrs) do
    Symphony1.Core.Linear.create_issue(config, attrs)
  end

  defp maybe_raise_on_stale_graph_regression!(graph_path, %Graph{} = graph) do
    case StaleGraphGuard.check(StaleGraphGuard.repo_root_for_graph(graph_path), graph_path, graph) do
      :ok -> :ok
      {:error, error} -> Mix.raise(StaleGraphGuard.error_message(error))
    end
  end
end
