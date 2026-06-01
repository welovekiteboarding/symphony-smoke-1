defmodule Symphony1.Project.RepoAdapter do
  require Logger

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})
  @proof_validation_scope "docs/live-proof-setup-run-merge.md"
  @proof_validation_command "test -f docs/live-proof-setup-run-merge.md"
  @setup_state_path ["config", "symphony_setup.state.json"]

  alias Symphony1.Observability.Recorder
  alias Symphony1.Planning.{Graph, ScopeCheck}
  alias Symphony1.Project.{DependencySafety, SetupState}

  @spec bootstrap_commands() :: [String.t()]
  def bootstrap_commands do
    [
      "git status --short",
      "mix deps.get"
    ]
  end

  @spec validation_commands() :: [String.t()]
  def validation_commands do
    [
      "mix test"
    ]
  end

  @spec finalize_workspace(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def finalize_workspace(attrs, runner \\ &System.cmd/3) do
    workspace = attrs.workspace

    with {:ok, issue_identifier} <- issue_identifier(attrs) do
      commit_message = "Implement #{issue_identifier}"

      Logger.info(
        "symphony.repo_adapter: finalize.start issue=#{issue_identifier} workspace=#{workspace}"
      )

      with {:ok, branch} <- current_branch(workspace),
           attrs = Map.put(attrs, :branch, branch),
           :ok <- run_bootstrap_commands(workspace, runner, attrs, issue_identifier),
           :ok <- run_setup_commands(workspace, runner, attrs, issue_identifier),
           {:ok, changed_files} <- changed_files(workspace),
           {:ok, finalization} <-
             finalize_changed_or_existing_workspace(
               attrs,
               branch,
               changed_files,
               commit_message,
               workspace,
               runner,
               issue_identifier
             ) do
        {:ok, finalization}
      end
    end
  end

  defp issue_identifier(%{issue_identifier: issue_identifier})
       when is_binary(issue_identifier) and issue_identifier != "" do
    {:ok, issue_identifier}
  end

  defp issue_identifier(%{issue: %{identifier: issue_identifier}})
       when is_binary(issue_identifier) and issue_identifier != "" do
    {:ok, issue_identifier}
  end

  defp issue_identifier(_attrs), do: {:error, :missing_issue_identifier}

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} ->
        {:ok, String.trim(branch)}

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp run_validation_commands(workspace, runner, attrs, issue_identifier) do
    with {:ok, commands} <- validation_commands_for(attrs) do
      run_shell_commands(commands, workspace, runner, issue_identifier, attrs)
    end
  end

  defp run_setup_commands(workspace, runner, attrs, issue_identifier) do
    attrs
    |> task_setup_commands()
    |> run_shell_commands(workspace, runner, issue_identifier, attrs)
  end

  defp task_setup_commands(%{task_context: %{validation: %{setup_commands: commands}}})
       when is_list(commands) do
    commands
  end

  defp task_setup_commands(_attrs), do: []

  defp task_validation_commands(%{task_context: %{validation: %{commands: commands}}})
       when is_list(commands) and commands != [] do
    commands
  end

  defp task_validation_commands(_attrs), do: nil

  defp validation_commands_for(attrs) do
    cond do
      commands = task_validation_commands(attrs) ->
        {:ok, commands}

      proof_validation_fallback_allowed?(attrs) ->
        {:ok, [@proof_validation_command]}

      Map.get(attrs, :project_type) == "product" ->
        {:error,
         {:missing_validation_commands,
          "product tasks must provide validation.commands unless explicitly proof-scoped"}}

      true ->
        {:ok, validation_commands()}
    end
  end

  defp enforce_scope(_workspace, attrs, changed_files) do
    task_context = Map.get(attrs, :task_context)

    result = ScopeCheck.evaluate(task_context || fallback_task(), changed_files)

    case result.status do
      :pass -> {:ok, result}
      :warn -> {:ok, result}
      :fail -> {:error, {:scope_violation, result}}
    end
  end

  defp run_bootstrap_commands(workspace, runner, attrs, issue_identifier) do
    run_shell_commands(bootstrap_commands(attrs), workspace, runner, issue_identifier, attrs)
  end

  defp bootstrap_commands(%{project_type: "product"}), do: ["git status --short"]
  defp bootstrap_commands(_attrs), do: bootstrap_commands()

  defp proof_validation_fallback_allowed?(attrs) do
    if Map.get(attrs, :project_type) == "product" do
      case Map.get(attrs, :task_context) do
        nil -> bootstrap_proof_issue?(attrs)
        %Graph.Task{} = task -> proof_scoped_task?(task)
        _other -> false
      end
    else
      false
    end
  end

  defp proof_scoped_task?(%Graph.Task{
         scope: %Graph.Scope{include: include, exclude: exclude}
       })
       when is_list(include) and is_list(exclude) do
    Enum.sort(Enum.uniq(include)) == [@proof_validation_scope] and exclude == []
  end

  defp proof_scoped_task?(_task), do: false

  defp bootstrap_proof_issue?(attrs) do
    current_issue_identifier(attrs) == bootstrap_proof_issue_identifier(attrs)
  end

  defp current_issue_identifier(%{issue_identifier: issue_identifier})
       when is_binary(issue_identifier) and issue_identifier != "" do
    issue_identifier
  end

  defp current_issue_identifier(%{issue: %{identifier: issue_identifier}})
       when is_binary(issue_identifier) and issue_identifier != "" do
    issue_identifier
  end

  defp current_issue_identifier(_attrs), do: nil

  defp bootstrap_proof_issue_identifier(attrs) do
    attrs
    |> setup_state_roots()
    |> Enum.find_value(fn root ->
      root
      |> load_setup_state()
      |> get_in(["proof_issue", "identifier"])
    end)
  end

  defp setup_state_roots(attrs) do
    [
      Map.get(attrs, :source_repo),
      Map.get(attrs, :observability_root),
      Map.get(attrs, :workspace)
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp load_setup_state(root) when is_binary(root) and root != "" do
    root
    |> then(&Path.join([&1 | @setup_state_path]))
    |> SetupState.read()
    |> case do
      {:ok, state} -> state
      {:error, _reason} -> %{}
    end
  end

  defp load_setup_state(_workspace), do: %{}

  defp run_shell_commands(commands, workspace, runner, issue_identifier, attrs) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case run_logged_command(
             runner,
             "zsh",
             ["-lc", command],
             workspace,
             issue_identifier,
             "finalize.shell",
             attrs
           ) do
        {:ok, _output} ->
          {:cont, :ok}

        {:error, exit_status, output} ->
          {:halt, {:error, {:command_failed, "zsh", exit_status, output}}}
      end
    end)
  end

  defp finalize_changed_or_existing_workspace(
         attrs,
         branch,
         [],
         commit_message,
         workspace,
         runner,
         issue_identifier
       ) do
    if Map.get(attrs, :reuse_pull_request, false) do
      with :ok <- run_validation_commands(workspace, runner, attrs, issue_identifier),
           :ok <- run_dependency_safety(workspace, runner, attrs, issue_identifier),
           {:ok, committed_files} <- committed_files_since_upstream(workspace),
           {:ok, scope_check} <- enforce_scope(workspace, attrs, committed_files),
           {:ok, pushed_existing_commits?} <-
             push_existing_commits_if_needed(workspace, branch, issue_identifier, attrs) do
        {:ok,
         %{
           branch: branch,
           commit_message: commit_message,
           issue_identifier: issue_identifier,
           pushed_existing_commits: pushed_existing_commits?,
           reused_existing_changes: true,
           scope_check: scope_check,
           workspace: workspace
         }}
      end
    else
      {:error, :no_changes}
    end
  end

  defp finalize_changed_or_existing_workspace(
         attrs,
         branch,
         changed_files,
         commit_message,
         workspace,
         runner,
         issue_identifier
       ) do
    with :ok <- ensure_working_tree_changes(changed_files),
         :ok <- run_validation_commands(workspace, runner, attrs, issue_identifier),
         :ok <- run_dependency_safety(workspace, runner, attrs, issue_identifier),
         {:ok, changed_files} <- changed_files(workspace),
         {:ok, scope_check} <- enforce_scope(workspace, attrs, changed_files),
         :ok <- stage_changed_files(workspace, changed_files, issue_identifier, attrs),
         :ok <- ensure_staged_changes(workspace),
         :ok <-
           run_command(
             "git",
             ["commit", "-m", commit_message],
             workspace,
             issue_identifier,
             attrs
           ),
         :ok <-
           run_command(
             "git",
             ["push", "-u", "origin", branch],
             workspace,
             issue_identifier,
             attrs
           ) do
      {:ok,
       %{
         branch: branch,
         commit_message: commit_message,
         issue_identifier: issue_identifier,
         scope_check: scope_check,
         workspace: workspace
       }}
    end
  end

  defp ensure_staged_changes(workspace) do
    case System.cmd("git", ["diff", "--cached", "--quiet"], cd: workspace, stderr_to_stdout: true) do
      {_output, 0} ->
        {:error, :no_changes}

      {_output, 1} ->
        :ok

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp ensure_working_tree_changes([]), do: {:error, :no_changes}
  defp ensure_working_tree_changes(_changed_files), do: :ok

  defp run_dependency_safety(workspace, runner, attrs, issue_identifier) do
    with {:ok, %{changed: changed?}} <- DependencySafety.run(workspace, runner, issue_identifier) do
      if changed? do
        run_validation_commands(workspace, runner, attrs, issue_identifier)
      else
        :ok
      end
    end
  end

  defp run_command(command, args, workspace, issue_identifier, attrs) do
    case run_logged_command(
           &System.cmd/3,
           command,
           args,
           workspace,
           issue_identifier,
           "finalize.command",
           attrs
         ) do
      {:ok, _output} -> :ok
      {:error, exit_status, output} -> {:error, {:command_failed, command, exit_status, output}}
    end
  end

  defp stage_changed_files(workspace, changed_files, issue_identifier, attrs) do
    run_command("git", ["add", "-A", "--" | changed_files], workspace, issue_identifier, attrs)
  end

  defp run_logged_command(runner, command, args, workspace, issue_identifier, stage, attrs) do
    command_string = Enum.join([command | args], " ")
    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "symphony.repo_adapter: #{stage} start issue=#{issue_identifier} cmd=#{inspect(command_string)} cwd=#{workspace}"
    )

    {output, exit_status} = runner.(command, args, cd: workspace, stderr_to_stdout: true)
    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    trimmed_output = String.trim(output)
    output_tail = output_tail(trimmed_output)

    log_level = if exit_status == 0, do: :info, else: :warning

    record_command_event(
      attrs,
      issue_identifier,
      workspace,
      command_string,
      stage,
      exit_status,
      elapsed_ms,
      output,
      output_tail
    )

    Logger.log(
      log_level,
      "symphony.repo_adapter: #{stage} finish issue=#{issue_identifier} cmd=#{inspect(command_string)} exit=#{exit_status} elapsed_ms=#{elapsed_ms} output=#{inspect(output_tail)}"
    )

    if exit_status == 0 do
      {:ok, trimmed_output}
    else
      {:error, exit_status, trimmed_output}
    end
  end

  defp changed_files(workspace) do
    case System.cmd("git", ["status", "--porcelain", "--untracked-files=all"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_changed_files(output)}

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp committed_files_since_upstream(workspace) do
    case System.cmd("git", ["diff", "--name-only", "@{u}..HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        {:ok, parse_committed_files(output)}

      {output, _exit_status} ->
        if upstream_missing?(output) do
          {:ok, []}
        else
          {:error, {:command_failed, "git", 1, String.trim(output)}}
        end
    end
  end

  defp parse_committed_files(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&internal_diagnostic_path?/1)
  end

  defp push_existing_commits_if_needed(workspace, branch, issue_identifier, attrs) do
    case System.cmd("git", ["rev-list", "--count", "@{u}..HEAD"],
           cd: workspace,
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        if output |> String.trim() |> String.to_integer() |> Kernel.>(0) do
          with :ok <-
                 run_command(
                   "git",
                   ["push", "-u", "origin", branch],
                   workspace,
                   issue_identifier,
                   attrs
                 ) do
            {:ok, true}
          end
        else
          {:ok, false}
        end

      {output, _exit_status} ->
        if upstream_missing?(output) do
          {:ok, false}
        else
          {:error, {:command_failed, "git", 1, String.trim(output)}}
        end
    end
  end

  defp upstream_missing?(output) when is_binary(output) do
    output =~ "no upstream configured" or output =~ "no upstream" or
      output =~ "unknown revision or path not in the working tree"
  end

  defp parse_changed_files(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&parse_changed_file/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reject(&internal_diagnostic_path?/1)
  end

  defp parse_changed_file(<<"?? ", path::binary>>), do: path

  defp parse_changed_file(line) do
    path = String.slice(line, 3..-1//1)

    case String.split(path, " -> ") do
      [_old, new] -> new
      [single] -> single
    end
  end

  defp internal_diagnostic_path?(".symphony"), do: true
  defp internal_diagnostic_path?(".symphony/"), do: true
  defp internal_diagnostic_path?("tmp/symphony"), do: true
  defp internal_diagnostic_path?("tmp/symphony/"), do: true

  defp internal_diagnostic_path?(path) do
    String.starts_with?(path, ".symphony/") or
      String.starts_with?(path, "tmp/symphony/")
  end

  defp record_command_event(
         attrs,
         issue_identifier,
         workspace,
         command_string,
         stage,
         exit_status,
         elapsed_ms,
         output,
         output_tail
       ) do
    case observability_root(attrs, workspace) do
      nil ->
        :ok

      root ->
        Recorder.record(root, "finalization_command_completed",
          issue_identifier: issue_identifier,
          graph_task_id: graph_task_id(attrs),
          phase: "finalization",
          severity: if(exit_status == 0, do: "info", else: "warning"),
          details: %{
            workspace_path: workspace,
            branch: Map.get(attrs, :branch),
            base_branch: Map.get(attrs, :base_branch),
            stage: stage,
            command: command_string,
            exit_status: exit_status,
            elapsed_ms: elapsed_ms,
            output_bytes: byte_size(output),
            output_tail: output_tail,
            failure_reason:
              if(exit_status == 0,
                do: nil,
                else: "command_failed: #{command_string} (exit #{exit_status})"
              )
          }
        )
    end
  end

  defp observability_root(attrs, _workspace) do
    Map.get(attrs, :observability_root) || Map.get(attrs, :source_repo)
  end

  defp graph_task_id(%{task_context: %Symphony1.Planning.Graph.Task{id: id}}), do: id
  defp graph_task_id(_attrs), do: nil

  defp output_tail(output) when is_binary(output) do
    output
    |> String.slice(-2_000, 2_000)
    |> to_string()
  end

  defp fallback_task do
    %Symphony1.Planning.Graph.Task{
      id: "unknown",
      title: "unknown",
      description: "",
      acceptance_criteria: [],
      dependencies: [],
      status: "pending",
      materialization: %Symphony1.Planning.Graph.Materialization{}
    }
  end
end
