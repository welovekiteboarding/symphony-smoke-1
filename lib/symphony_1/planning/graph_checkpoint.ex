defmodule Symphony1.Planning.GraphCheckpoint do
  @moduledoc """
  Creates a Git checkpoint commit for a completed planning graph when the graph
  file has uncommitted changes.
  """

  @default_commit_message "chore: checkpoint completed graph state"

  @type checkpoint_result ::
          {:ok, :noop}
          | {:ok,
             %{
               status: :committed,
               commit_sha: String.t(),
               graph_path: String.t(),
               relative_graph_path: String.t()
             }}
          | {:error,
             %{
               stage: atom(),
               graph_path: String.t(),
               relative_graph_path: String.t() | nil,
               repo_root: String.t() | nil,
               command: [String.t()],
               exit_status: integer() | nil,
               output: String.t(),
               reason: term() | nil
             }}

  @spec checkpoint(String.t(), keyword()) :: checkpoint_result()
  def checkpoint(graph_path, opts \\ []) when is_binary(graph_path) and is_list(opts) do
    runner = Keyword.get(opts, :runner, &System.cmd/3)
    expanded_graph_path = Path.expand(graph_path)

    with {:ok, repo_root} <- repo_root(expanded_graph_path, opts, runner),
         {:ok, relative_graph_path} <- relative_graph_path(expanded_graph_path, repo_root),
         {:ok, dirty?} <- graph_dirty?(runner, repo_root, expanded_graph_path, relative_graph_path),
         result <- maybe_commit_graph(dirty?, runner, repo_root, expanded_graph_path, relative_graph_path) do
      result
    end
  end

  defp maybe_commit_graph(false, _runner, _repo_root, _graph_path, _relative_graph_path), do: {:ok, :noop}

  defp maybe_commit_graph(true, runner, repo_root, graph_path, relative_graph_path) do
    commit_message = @default_commit_message

    with :ok <- git_add(runner, repo_root, graph_path, relative_graph_path),
         :ok <- git_commit(runner, repo_root, graph_path, relative_graph_path, commit_message),
         {:ok, commit_sha} <- git_rev_parse(runner, repo_root, graph_path, relative_graph_path) do
      {:ok,
       %{
         status: :committed,
         commit_sha: commit_sha,
         graph_path: graph_path,
         relative_graph_path: relative_graph_path
       }}
    end
  end

  defp configured_repo_root(opts) do
    case Keyword.get(opts, :repo_root) do
      repo_root when is_binary(repo_root) -> {:ok, Path.expand(repo_root)}
      _ -> :error
    end
  end

  defp repo_root(graph_path, opts, runner) do
    case configured_repo_root(opts) do
      {:ok, repo_root} ->
        {:ok, repo_root}

      :error ->
        detect_repo_root(graph_path, runner)
    end
  end

  defp detect_repo_root(graph_path, runner) do
    graph_dir = Path.dirname(graph_path)
    command = ["rev-parse", "--show-toplevel"]

    case runner.("git", command, cd: graph_dir, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, output |> String.trim() |> Path.expand()}

      {output, exit_status} ->
        {:error,
         failure(
           :git_repo_root,
           graph_path,
           nil,
           nil,
           ["git" | command],
           exit_status,
           output,
           nil
         )}
    end
  end

  defp relative_graph_path(graph_path, repo_root) do
    relative_graph_path = Path.relative_to(graph_path, repo_root)

    if String.starts_with?(relative_graph_path, "../") or relative_graph_path == ".." do
      {:error,
       failure(
         :graph_path_not_in_repo,
         graph_path,
         nil,
         repo_root,
         [],
         nil,
         "",
         :graph_path_outside_repo
       )}
    else
      {:ok, relative_graph_path}
    end
  end

  defp graph_dirty?(runner, repo_root, graph_path, relative_graph_path) do
    command = ["status", "--porcelain", "--", relative_graph_path]

    case runner.("git", command, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output) != ""}

      {output, exit_status} ->
        {:error,
         failure(
           :git_status,
           graph_path,
           relative_graph_path,
           repo_root,
           ["git" | command],
           exit_status,
           output,
           nil
         )}
    end
  end

  defp git_add(runner, repo_root, graph_path, relative_graph_path) do
    command = ["add", "--", relative_graph_path]

    case runner.("git", command, cd: repo_root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, exit_status} ->
        {:error,
         failure(
           :git_add,
           graph_path,
           relative_graph_path,
           repo_root,
           ["git" | command],
           exit_status,
           output,
           nil
         )}
    end
  end

  defp git_commit(runner, repo_root, graph_path, relative_graph_path, commit_message) do
    command = ["commit", "--only", "-m", commit_message, "--", relative_graph_path]

    case runner.("git", command, cd: repo_root, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, exit_status} ->
        {:error,
         failure(
           :git_commit,
           graph_path,
           relative_graph_path,
           repo_root,
           ["git" | command],
           exit_status,
           output,
           nil
         )}
    end
  end

  defp git_rev_parse(runner, repo_root, graph_path, relative_graph_path) do
    command = ["rev-parse", "HEAD"]

    case runner.("git", command, cd: repo_root, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_status} ->
        {:error,
         failure(
           :git_rev_parse,
           graph_path,
           relative_graph_path,
           repo_root,
           ["git" | command],
           exit_status,
           output,
           nil
         )}
    end
  end

  defp failure(stage, graph_path, relative_graph_path, repo_root, command, exit_status, output, reason) do
    %{
      stage: stage,
      graph_path: graph_path,
      relative_graph_path: relative_graph_path,
      repo_root: repo_root,
      command: command,
      exit_status: exit_status,
      output: output,
      reason: reason
    }
  end
end
