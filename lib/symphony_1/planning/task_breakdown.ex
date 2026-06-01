defmodule Symphony1.Planning.TaskBreakdown do
  @moduledoc """
  Rewrites oversized graph tasks into smaller dependency-chained tasks.
  """

  alias Symphony1.Planning.Graph

  defmodule Proposal do
    @moduledoc false

    defstruct [:task_id, :child_ids]
  end

  @spec break_down(Graph.t(), [String.t()]) ::
          {:ok, Graph.t(), Proposal.t()}
          | {:ok, Graph.t(), [Proposal.t()]}
          | {:error, term()}
  def break_down(%Graph{} = graph, [task_id]) do
    with {:ok, updated_graph, proposal} <- break_down_one(graph, task_id) do
      {:ok, updated_graph, proposal}
    end
  end

  def break_down(%Graph{} = graph, task_ids) do
    Enum.reduce_while(task_ids, {:ok, graph, []}, fn task_id, {:ok, current_graph, proposals} ->
      case break_down_one(current_graph, task_id) do
        {:ok, updated_graph, proposal} -> {:cont, {:ok, updated_graph, proposals ++ [proposal]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp break_down_one(%Graph{} = graph, task_id) do
    case Enum.find_index(graph.tasks, &(&1.id == task_id)) do
      nil ->
        {:error, {:task_not_found, task_id}}

      index ->
        task = Enum.at(graph.tasks, index)
        do_break_down_one(graph, index, task)
    end
  end

  defp do_break_down_one(_graph, _index, %Graph.Task{id: task_id, status: "done"}) do
    {:error, {:cannot_break_down_done_task, task_id}}
  end

  defp do_break_down_one(%Graph{} = graph, index, %Graph.Task{} = task) do
    child_ids = child_ids(task.id)

    case existing_child_ids(graph, child_ids) do
      [] ->
        children = build_children(task, child_ids)
        final_child_id = List.last(child_ids)

        updated_tasks =
          graph.tasks
          |> List.replace_at(index, children)
          |> List.flatten()
          |> Enum.map(&rewire_dependency(&1, task.id, final_child_id, child_ids))

        updated_graph = %{graph | tasks: updated_tasks}

        with :ok <- Graph.validate(updated_graph) do
          {:ok, updated_graph, %Proposal{task_id: task.id, child_ids: child_ids}}
        end

      existing ->
        {:error, {:child_ids_already_exist, task.id, existing}}
    end
  end

  defp child_ids(task_id), do: Enum.map(~w(a b c d), &"#{task_id}#{&1}")

  defp existing_child_ids(%Graph{tasks: tasks}, child_ids) do
    existing_ids = MapSet.new(tasks, & &1.id)
    Enum.filter(child_ids, &MapSet.member?(existing_ids, &1))
  end

  defp build_children(task, [foundation_id, core_id, advanced_id, integration_id]) do
    [
      child_task(task, foundation_id,
        title: "#{task.title}: foundation",
        description:
          "Breakdown of #{task.id}. Define the minimal types, interfaces, helpers, and test seams needed before implementation.",
        dependencies: task.dependencies,
        scope: partition_scope(task.scope, :foundation),
        acceptance_criteria:
          partition_criteria(task, 0, [
            "Public types and helper seams are defined for #{task.id}"
          ])
      ),
      child_task(task, core_id,
        title: "#{task.title}: core behavior",
        description:
          "Breakdown of #{task.id}. Implement the smallest working behavior that satisfies the core user-facing requirement.",
        dependencies: [foundation_id],
        scope: partition_scope(task.scope, :core),
        acceptance_criteria:
          partition_criteria(task, 1, [
            "Core behavior works for the smallest useful case"
          ])
      ),
      child_task(task, advanced_id,
        title: "#{task.title}: advanced behavior",
        description:
          "Breakdown of #{task.id}. Add advanced behavior, quality constraints, determinism, and performance-sensitive logic.",
        dependencies: [core_id],
        scope: partition_scope(task.scope, :advanced),
        acceptance_criteria:
          partition_criteria(task, 2, [
            "Advanced behavior is deterministic and bounded enough for normal operation"
          ])
      ),
      child_task(task, integration_id,
        title: "#{task.title}: integration",
        description:
          "Breakdown of #{task.id}. Wire the completed behavior into integration/runtime surfaces and keep validation passing.",
        dependencies: [advanced_id],
        scope: partition_scope(task.scope, :integration),
        acceptance_criteria:
          partition_criteria(task, 3, [
            "Completed behavior is wired into the integration surface"
          ])
      )
    ]
  end

  defp child_task(task, id, opts) do
    %{
      task
      | id: id,
        title: Keyword.fetch!(opts, :title),
        description: Keyword.fetch!(opts, :description),
        acceptance_criteria: Keyword.fetch!(opts, :acceptance_criteria),
        dependencies: Keyword.fetch!(opts, :dependencies),
        status: "pending",
        materialization: %Graph.Materialization{},
        scope: Keyword.fetch!(opts, :scope),
        last_failure: nil
    }
  end

  defp rewire_dependency(%Graph.Task{} = task, old_id, new_id, child_ids) do
    if task.id in child_ids do
      task
    else
      rewire_existing_dependencies(task, old_id, new_id)
    end
  end

  defp rewire_existing_dependencies(%Graph.Task{} = task, old_id, new_id) do
    dependencies =
      Enum.map(task.dependencies, fn
        ^old_id -> new_id
        dependency -> dependency
      end)

    %{task | dependencies: dependencies}
  end

  defp partition_scope(nil, _kind), do: nil

  defp partition_scope(%Graph.Scope{} = scope, kind) do
    include = scope.include || []

    preferred =
      include
      |> Enum.filter(&scope_matches_kind?(&1, kind))
      |> case do
        [] -> fallback_scope(include, kind)
        matched -> matched
      end

    %Graph.Scope{include: preferred, exclude: scope.exclude || []}
  end

  defp fallback_scope([], _kind), do: []

  defp fallback_scope(include, kind) do
    include
    |> Enum.with_index()
    |> Enum.filter(fn {_path, index} -> rem(index, 4) == kind_index(kind) end)
    |> Enum.map(fn {path, _index} -> path end)
    |> case do
      [] -> [List.first(include)]
      paths -> paths
    end
  end

  defp kind_index(:foundation), do: 0
  defp kind_index(:core), do: 1
  defp kind_index(:advanced), do: 2
  defp kind_index(:integration), do: 3

  defp scope_matches_kind?(path, :foundation),
    do: String.contains?(path, "types") or String.contains?(path, "domain")

  defp scope_matches_kind?(path, :core),
    do: String.contains?(path, "ai") or String.contains?(path, "chess")

  defp scope_matches_kind?(path, :advanced),
    do: String.contains?(path, "ai") or String.contains?(path, "chess")

  defp scope_matches_kind?(path, :integration),
    do: String.contains?(path, "worker") or String.contains?(path, "ui")

  defp partition_criteria(task, index, fallback) do
    criteria = task.acceptance_criteria || []
    chunk_size = max(ceil(length(criteria) / 4), 1)

    criteria
    |> Enum.chunk_every(chunk_size)
    |> Enum.at(index, [])
    |> case do
      [] -> fallback
      partition -> partition
    end
  end
end
