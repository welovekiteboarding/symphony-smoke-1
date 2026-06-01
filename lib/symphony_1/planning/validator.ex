defmodule Symphony1.Planning.Validator do
  @moduledoc """
  Read-only planning validation boundary for on-disk graph files.
  """

  alias Symphony1.Planning.Graph
  alias Symphony1.Project.SetupIntent

  @default_project_type "symphony"
  @proof_validation_scope "docs/live-proof-setup-run-merge.md"

  @spec validate_file(String.t(), keyword()) :: :ok | {:error, term()}
  def validate_file(path, opts \\ []) do
    project_type = resolve_project_type(path, opts)

    with {:ok, graph} <- Graph.load(path),
         :ok <- Graph.validate(graph),
         :ok <- validate_task_admissions(graph.tasks, project_type) do
      :ok
    end
  end

  @spec validate_task_admission(Graph.Task.t(), keyword()) :: :ok | {:error, term()}
  def validate_task_admission(%Graph.Task{} = task, opts \\ []) do
    project_type = Keyword.get(opts, :project_type, @default_project_type)

    with :ok <- Graph.validate_task_admission(task),
         :ok <- validate_product_task(task, project_type) do
      :ok
    end
  end

  defp validate_task_admissions(tasks, project_type) do
    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      case validate_task_admission(task, project_type: project_type) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_product_task(_task, project_type) when project_type != "product", do: :ok

  defp validate_product_task(task, "product") do
    if explicit_validation_commands?(task) or proof_scoped_task?(task) do
      :ok
    else
      {:error,
       {:admission_failed, task.id,
        "product tasks must provide validation.commands unless explicitly proof-scoped"}}
    end
  end

  defp explicit_validation_commands?(%Graph.Task{
         validation: %Graph.Validation{commands: commands}
       })
       when is_list(commands) do
    commands != []
  end

  defp explicit_validation_commands?(_task), do: false

  defp proof_scoped_task?(%Graph.Task{
         scope: %Graph.Scope{include: include, exclude: exclude}
       })
       when is_list(include) and is_list(exclude) do
    Enum.sort(Enum.uniq(include)) == [@proof_validation_scope] and exclude == []
  end

  defp proof_scoped_task?(_task), do: false

  defp resolve_project_type(path, opts) do
    Keyword.get(opts, :project_type) ||
      infer_project_type_from_graph_path(path) ||
      @default_project_type
  end

  defp infer_project_type_from_graph_path(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> find_setup_intent_path()
    |> load_project_type()
  end

  defp find_setup_intent_path(dir) do
    candidate = Path.join([dir, "config", "symphony_setup.json"])

    cond do
      File.exists?(candidate) ->
        candidate

      parent_dir(dir) == dir ->
        nil

      true ->
        find_setup_intent_path(parent_dir(dir))
    end
  end

  defp load_project_type(nil), do: nil

  defp load_project_type(path) do
    case SetupIntent.load(path) do
      {:ok, intent} -> get_in(intent, ["project", "type"])
      {:error, _reason} -> nil
    end
  end

  defp parent_dir(dir), do: Path.dirname(dir)
end
