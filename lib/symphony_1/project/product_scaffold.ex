defmodule Symphony1.Project.ProductScaffold do
  alias Symphony1.Project.ProductTemplate
  alias Symphony1.Project.TeamKey

  @spec generate(map()) :: {:ok, map()} | {:error, term()}
  def generate(
        %{project_name: project_name, root_path: root_path, graph_path: graph_path} = attrs
      ) do
    project_path = Path.join(root_path, project_name)
    command_runner = Map.get(attrs, :command_runner, &System.cmd/3)
    github_owner = Map.get(attrs, :github_owner) || "OWNER"

    with {:ok, graph_json} <- read_fresh_graph_template(graph_path),
         :ok <- File.mkdir_p(project_path),
         :ok <-
           write_files(
             project_path,
             ProductTemplate.files(assigns(attrs, github_owner, graph_json))
           ),
         {_, 0} <-
           System.cmd("git", ["init", "-b", "main"], cd: project_path, stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["add", "."], cd: project_path, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd(
             "git",
             [
               "-c",
               "user.name=Symphony",
               "-c",
               "user.email=symphony@example.com",
               "commit",
               "-m",
               "Bootstrap product control repo"
             ],
             cd: project_path,
             stderr_to_stdout: true
           ),
         :ok <- maybe_create_github_repo(attrs, project_path, command_runner) do
      {:ok, %{project_path: project_path}}
    else
      {:error, reason} -> {:error, reason}
      {output, status} -> {:error, {:command_failed, "git", status, String.trim(output)}}
    end
  end

  def generate(_attrs), do: {:error, :missing_graph_path}

  defp read_fresh_graph_template(graph_path) do
    with {:ok, graph_json} <- File.read(graph_path),
         {:ok, decoded} <- Jason.decode(graph_json) do
      {:ok, Jason.encode!(reset_graph_execution_state(decoded), pretty: true)}
    else
      {:error, %Jason.DecodeError{} = reason} -> {:error, {:invalid_graph_json, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reset_graph_execution_state(%{"tasks" => tasks} = graph) when is_list(tasks) do
    Map.put(graph, "tasks", Enum.map(tasks, &reset_task_execution_state/1))
  end

  defp reset_graph_execution_state(graph), do: graph

  defp reset_task_execution_state(task) when is_map(task) do
    task
    |> Map.put("status", "pending")
    |> Map.put("materialization", %{
      "materialized" => false,
      "linear_issue_id" => nil,
      "linear_issue_identifier" => nil
    })
    |> Map.delete("last_failure")
  end

  defp assigns(attrs, github_owner, graph_json) do
    project_name = Map.fetch!(attrs, :project_name)
    module_name = module_name(project_name)

    %{
      github_repo: "#{github_owner}/#{project_name}",
      graph_json: graph_json,
      linear_team_key: Map.get(attrs, :linear_team_key, TeamKey.default_team_key(project_name)),
      linear_team_name: Map.get(attrs, :linear_team_name, module_name),
      project_name: project_name
    }
  end

  defp write_files(project_path, files) do
    Enum.reduce_while(files, :ok, fn {relative_path, contents}, :ok ->
      path = Path.join(project_path, relative_path)

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(path, contents) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_create_github_repo(
         %{github: true, github_owner: owner} = attrs,
         project_path,
         command_runner
       ) do
    visibility = if Map.get(attrs, :private, false), do: "--private", else: "--public"
    repo = "#{owner}/#{Path.basename(project_path)}"

    case command_runner.(
           "gh",
           [
             "repo",
             "create",
             repo,
             visibility,
             "--source",
             project_path,
             "--remote",
             "origin",
             "--push"
           ],
           []
         ) do
      {_output, 0} -> :ok
      {output, status} -> {:error, {:command_failed, "gh", status, String.trim(output)}}
    end
  end

  defp maybe_create_github_repo(_attrs, _project_path, _command_runner), do: :ok

  defp module_name(project_name) do
    project_name
    |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
    |> Enum.map(&Macro.camelize/1)
    |> Enum.join()
  end
end
