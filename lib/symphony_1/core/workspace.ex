defmodule Symphony1.Core.Workspace do
  @valid_issue_id ~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/
  @default_workspace_base_dir "symphony-workspaces"
  @workspace_metadata_relpath [".symphony", "workspace.json"]
  @workspace_registration_dir "symphony-workspace-registry"
  @workspace_root_registration_subdir "roots"

  @spec path_for_issue(String.t(), String.t()) :: String.t()
  def path_for_issue(root, issue_id) do
    case workspace_path(root, issue_id) do
      {:ok, path} ->
        path

      {:error, {:invalid_issue_id, invalid_issue_id}} ->
        raise ArgumentError, "invalid workspace issue identifier: #{inspect(invalid_issue_id)}"
    end
  end

  @spec resolve_base_branch(String.t() | nil, String.t() | nil) :: String.t()
  def resolve_base_branch(source_repo, branch \\ nil)

  def resolve_base_branch(source_repo, branch) when is_binary(source_repo) do
    case normalize_branch_name(branch) do
      "" -> preferred_base_branch(source_repo)
      requested_branch -> requested_branch
    end
  end

  def resolve_base_branch(_source_repo, branch) do
    normalize_branch_name(branch)
  end

  @spec create(map()) :: {:ok, String.t()} | {:error, term()}
  def create(%{root: root, issue_id: issue_id} = attrs) do
    with {:ok, workspace_path} <- workspace_path(root, issue_id),
         :ok <- File.mkdir_p(root),
         :ok <- materialize_workspace(workspace_path, attrs),
         {:ok, root_registration} <- ensure_workspace_root_registration(root),
         {:ok, registration} <-
           build_workspace_registration(
             workspace_path,
             root,
             issue_id,
             root_registration.token
           ),
         :ok <- write_workspace_metadata(workspace_path, registration),
         :ok <- register_workspace(registration),
         :ok <- trust_workspace_root(root) do
      {:ok, workspace_path}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec cleanup(String.t()) :: :ok | {:error, term()}
  def cleanup(path) do
    normalized_path = normalize_cleanup_path(path)
    expanded_path = Path.expand(normalized_path)

    with :ok <- validate_cleanup_path(normalized_path, expanded_path) do
      cleanup_existing_workspace(normalized_path, expanded_path)
    end
  end

  @spec cleanup(String.t(), String.t()) :: :ok | {:error, term()}
  def cleanup(root, issue_id) do
    with {:ok, workspace_path} <- workspace_path(root, issue_id),
         expanded_root = Path.expand(root),
         expanded_path = Path.expand(workspace_path),
         :ok <- ensure_trusted_workspace_root(expanded_root, expanded_path),
         :ok <- ensure_path_within_root(expanded_path, expanded_root) do
      do_cleanup(expanded_path)
    end
  end

  defp do_cleanup(path) do
    with :ok <- cleanup_worktree(path),
         {:ok, _paths} <- File.rm_rf(path) do
      unregister_workspace(path)
      :ok
    else
      {:error, :enoent, _path} ->
        unregister_workspace(path)
        :ok

      {:error, reason, _path} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp materialize_workspace(workspace_path, %{source_repo: source_repo, branch: branch} = attrs) do
    with {:ok, start_point} <- workspace_start_point(source_repo, attrs) do
      cond do
        File.dir?(workspace_path) ->
          reuse_existing_workspace(workspace_path, branch)

        ref_exists?(source_repo, branch) ->
          add_existing_branch_worktree(source_repo, branch, workspace_path)

        true ->
          add_new_branch_worktree(source_repo, branch, workspace_path, start_point)
      end
    end
  end

  defp materialize_workspace(workspace_path, _attrs) do
    case File.mkdir_p(workspace_path) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_worktree(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--git-common-dir"], stderr_to_stdout: true) do
      {git_common_dir, 0} ->
        common_dir = git_common_dir |> String.trim() |> Path.expand(path)

        case System.cmd(
               "git",
               ["--git-dir", common_dir, "worktree", "remove", "--force", path],
               stderr_to_stdout: true
             ) do
          {_output, 0} -> :ok
          {output, _exit_status} -> {:error, String.trim(output)}
        end

      {_output, _exit_status} ->
        :ok
    end
  end

  defp reuse_existing_workspace(workspace_path, branch) do
    case System.cmd("git", ["branch", "--show-current"],
           cd: workspace_path,
           stderr_to_stdout: true
         ) do
      {^branch <> "\n", 0} ->
        :ok

      {output, 0} ->
        {:error, {:workspace_branch_mismatch, workspace_path, String.trim(output), branch}}

      {output, _exit_status} ->
        {:error, {:workspace_not_reusable, workspace_path, String.trim(output)}}
    end
  end

  defp workspace_start_point(source_repo, attrs) do
    base_branch = resolve_base_branch(source_repo, Map.get(attrs, :base_branch))

    cond do
      base_branch == "" ->
        {:ok, "HEAD"}

      remote_ref_exists?(source_repo, base_branch) ->
        {:ok, "origin/#{base_branch}"}

      published_branch?(source_repo, base_branch) ->
        with :ok <- fetch_remote_branch(source_repo, base_branch),
             true <- remote_ref_exists?(source_repo, base_branch) do
          {:ok, "origin/#{base_branch}"}
        else
          false ->
            {:error, {:missing_remote_tracking_base_branch, base_branch}}

          {:error, reason} ->
            {:error, {:base_branch_fetch_failed, base_branch, reason}}
        end

      ref_exists?(source_repo, base_branch) ->
        {:ok, base_branch}

      true ->
        {:ok, "HEAD"}
    end
  end

  defp preferred_base_branch(source_repo) do
    current_branch = current_branch(source_repo)

    case visible_base_branch(source_repo, current_branch) do
      {:ok, branch} -> branch
      :error -> current_branch
    end
  end

  defp current_branch(source_repo) do
    case System.cmd("git", ["-C", source_repo, "branch", "--show-current"],
           stderr_to_stdout: true
         ) do
      {branch, 0} ->
        normalize_branch_name(branch)

      {_output, _status} ->
        "main"
    end
  end

  defp visible_base_branch(_source_repo, ""), do: :error

  defp visible_base_branch(source_repo, current_branch) do
    case published_branch?(source_repo, current_branch) do
      true -> {:ok, current_branch}
      false -> remote_default_branch(source_repo)
    end
  end

  defp remote_default_branch(source_repo) do
    case origin_head_branch(source_repo) do
      {:ok, branch} ->
        if published_branch?(source_repo, branch) do
          {:ok, branch}
        else
          remote_head_branch(source_repo)
        end

      :error ->
        remote_head_branch(source_repo)
    end
  end

  defp origin_head_branch(source_repo) do
    case System.cmd(
           "git",
           ["-C", source_repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        branch =
          output
          |> normalize_branch_name()
          |> String.replace_prefix("origin/", "")

        if branch == "", do: :error, else: {:ok, branch}

      {_output, _status} ->
        :error
    end
  end

  defp remote_head_branch(source_repo) do
    case System.cmd("git", ["-C", source_repo, "ls-remote", "--symref", "origin", "HEAD"],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        parse_remote_head_branch(output)

      {_output, _status} ->
        :error
    end
  end

  defp remote_ref_exists?(_source_repo, ""), do: false
  defp remote_ref_exists?(source_repo, branch), do: ref_exists?(source_repo, "origin/#{branch}")

  defp published_branch?(_source_repo, ""), do: false

  defp published_branch?(source_repo, branch) do
    case System.cmd(
           "git",
           ["-C", source_repo, "ls-remote", "--exit-code", "--heads", "origin", branch],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _exit_status} -> false
    end
  end

  defp fetch_remote_branch(source_repo, branch) do
    case System.cmd(
           "git",
           [
             "-C",
             source_repo,
             "fetch",
             "origin",
             "refs/heads/#{branch}:refs/remotes/origin/#{branch}"
           ],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  end

  defp ref_exists?(source_repo, ref) do
    case System.cmd("git", ["-C", source_repo, "rev-parse", "--verify", ref],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> true
      {_output, _exit_status} -> false
    end
  end

  defp add_existing_branch_worktree(source_repo, branch, workspace_path) do
    case System.cmd(
           "git",
           ["-C", source_repo, "worktree", "add", workspace_path, branch],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  end

  defp add_new_branch_worktree(source_repo, branch, workspace_path, start_point) do
    case System.cmd(
           "git",
           ["-C", source_repo, "worktree", "add", "-b", branch, workspace_path, start_point],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {output, _exit_status} -> {:error, String.trim(output)}
    end
  end

  defp normalize_branch_name(branch) when is_binary(branch) do
    String.trim(branch)
  end

  defp normalize_branch_name(branch) when is_list(branch) do
    branch
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp normalize_branch_name(_branch), do: ""

  defp workspace_path(root, issue_id) do
    with {:ok, issue_dir} <- issue_directory_name(issue_id) do
      {:ok, Path.join(root, issue_dir)}
    end
  end

  defp issue_directory_name(issue_id) do
    normalized_issue_id = normalize_issue_id(issue_id)

    if normalized_issue_id != "" and Regex.match?(@valid_issue_id, normalized_issue_id) do
      {:ok, normalized_issue_id}
    else
      {:error, {:invalid_issue_id, issue_id}}
    end
  end

  defp normalize_issue_id(issue_id) when is_binary(issue_id) do
    String.trim(issue_id)
  end

  defp normalize_issue_id(issue_id) when is_list(issue_id) do
    issue_id
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp normalize_issue_id(_issue_id), do: ""

  defp build_workspace_registration(workspace_path, root, issue_id, token) do
    with {:ok, normalized_issue_id} <- issue_directory_name(issue_id) do
      {:ok,
       %{
         issue_id: normalized_issue_id,
         path: Path.expand(workspace_path),
         root: Path.expand(root),
         token: token
       }}
    end
  end

  defp write_workspace_metadata(workspace_path, %{issue_id: issue_id, root: root, token: token}) do
    metadata_path = workspace_metadata_path(workspace_path)

    with :ok <- File.mkdir_p(Path.dirname(metadata_path)),
         :ok <-
           File.write(
             metadata_path,
             Jason.encode!(%{
               "issue_id" => issue_id,
               "root" => root,
               "token" => token
             })
           ) do
      :ok
    end
  end

  defp workspace_metadata_path(workspace_path) do
    Path.join([workspace_path | @workspace_metadata_relpath])
  end

  defp read_workspace_metadata(workspace_path) do
    metadata_path = workspace_metadata_path(workspace_path)

    case File.read(metadata_path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             root when is_binary(root) <- Map.get(decoded, "root"),
             issue_id when is_binary(issue_id) <- Map.get(decoded, "issue_id"),
             token when is_binary(token) or is_nil(token) <- Map.get(decoded, "token"),
             {:ok, _expected_path} <- workspace_path(root, issue_id) do
          {:ok, %{issue_id: issue_id, root: root, token: token}}
        else
          _ -> {:error, {:invalid_workspace_metadata, metadata_path}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:workspace_metadata_read_failed, metadata_path, reason}}
    end
  end

  defp workspace_registration_root do
    :symphony_1
    |> Application.get_env(
      :workspace_registry_root,
      Path.join(System.tmp_dir!(), @workspace_registration_dir)
    )
    |> Path.expand()
  end

  defp workspace_registration_path(workspace_path) do
    entry_name =
      :crypto.hash(:sha256, workspace_path)
      |> Base.url_encode64(padding: false)

    Path.join(workspace_registration_root(), "#{entry_name}.json")
  end

  defp workspace_root_registration_path(root) do
    entry_name =
      :crypto.hash(:sha256, Path.expand(root))
      |> Base.url_encode64(padding: false)

    Path.join([
      workspace_registration_root(),
      @workspace_root_registration_subdir,
      "#{entry_name}.json"
    ])
  end

  defp workspace_registration_token do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_workspace_root_registration(root) do
    expanded_root = Path.expand(root)

    case read_workspace_root_registration(expanded_root) do
      {:ok, registration} ->
        {:ok, registration}

      :missing ->
        register_workspace_root(expanded_root)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp workspace_base do
    :symphony_1
    |> Application.get_env(
      :workspace_base,
      Path.join(System.tmp_dir!(), @default_workspace_base_dir)
    )
    |> Path.expand()
  end

  defp workspace_allowed_roots do
    :symphony_1
    |> Application.get_env(:workspace_allowed_roots, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
  end

  defp trust_workspace_root(root) do
    expanded_root = Path.expand(root)
    allowed_roots = workspace_allowed_roots()

    Application.put_env(
      :symphony_1,
      :workspace_allowed_roots,
      Enum.uniq([expanded_root | allowed_roots])
    )

    :ok
  end

  defp register_workspace_root(root) do
    registration_path = workspace_root_registration_path(root)

    registration = %{
      root: Path.expand(root),
      token: workspace_registration_token()
    }

    with :ok <- File.mkdir_p(Path.dirname(registration_path)),
         :ok <-
           File.write(
             registration_path,
             Jason.encode!(%{
               "root" => registration.root,
               "token" => registration.token
             })
           ) do
      {:ok, registration}
    end
  end

  defp read_workspace_root_registration(root) do
    expanded_root = Path.expand(root)
    registration_path = workspace_root_registration_path(expanded_root)

    case File.read(registration_path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             ^expanded_root <- Map.get(decoded, "root"),
             token when is_binary(token) and token != "" <- Map.get(decoded, "token") do
          {:ok, %{root: expanded_root, token: token}}
        else
          _ -> {:error, {:invalid_workspace_root_registration, registration_path}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:workspace_root_registration_read_failed, registration_path, reason}}
    end
  end

  defp register_workspace(%{path: path, root: root, issue_id: issue_id, token: token}) do
    registration_path = workspace_registration_path(path)

    with :ok <- File.mkdir_p(Path.dirname(registration_path)),
         :ok <-
           File.write(
             registration_path,
             Jason.encode!(%{
               "issue_id" => issue_id,
               "path" => path,
               "root" => root,
               "token" => token
             })
           ) do
      :ok
    end
  end

  defp unregister_workspace(workspace_path) do
    workspace_path
    |> Path.expand()
    |> workspace_registration_path()
    |> File.rm()

    :ok
  end

  defp read_workspace_registration(workspace_path) do
    expanded_path = Path.expand(workspace_path)
    registration_path = workspace_registration_path(expanded_path)

    case File.read(registration_path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents),
             ^expanded_path <- Map.get(decoded, "path"),
             root when is_binary(root) <- Map.get(decoded, "root"),
             issue_id when is_binary(issue_id) <- Map.get(decoded, "issue_id"),
             token when is_binary(token) and token != "" <- Map.get(decoded, "token"),
             {:ok, expected_path} <- workspace_path(root, issue_id),
             true <- Path.expand(expected_path) == expanded_path do
          {:ok, %{issue_id: issue_id, path: expanded_path, root: root, token: token}}
        else
          false -> {:error, {:invalid_workspace_registration, registration_path}}
          _ -> {:error, {:invalid_workspace_registration, registration_path}}
        end

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        {:error, {:workspace_registration_read_failed, registration_path, reason}}
    end
  end

  defp validate_cleanup_path(raw_path, expanded_path) do
    with :ok <- ensure_safe_cleanup_path(raw_path),
         {:ok, _issue_dir} <- issue_directory_name(Path.basename(expanded_path)),
         :ok <- ensure_non_root_cleanup_parent(Path.dirname(expanded_path)) do
      :ok
    else
      {:error, {:invalid_issue_id, _} = reason} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_safe_cleanup_path(path) do
    if path == "" or unsafe_cleanup_path?(path) do
      {:error, {:unsafe_workspace_cleanup_path, path}}
    else
      :ok
    end
  end

  defp unsafe_cleanup_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 in [".", ".."]))
  end

  defp ensure_non_root_cleanup_parent(root) do
    if root in ["", "/", "."] do
      {:error, {:unsafe_workspace_cleanup_path, root}}
    else
      :ok
    end
  end

  defp ensure_path_within_root(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    root_prefix = expanded_root <> "/"

    if String.starts_with?(expanded_path, root_prefix) do
      :ok
    else
      {:error, {:workspace_path_outside_root, expanded_path, expanded_root}}
    end
  end

  defp normalize_cleanup_path(path) when is_binary(path), do: String.trim(path)

  defp normalize_cleanup_path(path) when is_list(path) do
    path
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp normalize_cleanup_path(_path), do: ""

  defp parse_remote_head_branch(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn
      "ref: refs/heads/" <> rest ->
        case String.split(rest, "\t", parts: 2) do
          [branch, "HEAD"] when branch != "" -> branch
          _ -> nil
        end

      _line ->
        nil
    end)
    |> case do
      nil -> :error
      branch -> {:ok, branch}
    end
  end

  defp cleanup_existing_workspace(normalized_path, expanded_path) do
    if File.exists?(expanded_path) do
      with :ok <- authorize_cleanup_target(normalized_path, expanded_path) do
        do_cleanup(expanded_path)
      end
    else
      unregister_workspace(expanded_path)
      :ok
    end
  end

  defp authorize_cleanup_target(normalized_path, expanded_path) do
    case {read_workspace_registration(expanded_path), read_workspace_metadata(expanded_path)} do
      {{:ok, registration}, {:ok, metadata}} ->
        ensure_cleanup_target_matches_registration(
          normalized_path,
          expanded_path,
          registration,
          metadata
        )

      {:missing, {:ok, metadata}} ->
        ensure_cleanup_target_matches_root_registration(normalized_path, expanded_path, metadata)

      {{:error, reason}, _metadata} ->
        {:error, reason}

      {_registration, {:error, reason}} ->
        {:error, reason}

      {_registration, :missing} ->
        {:error, {:unsafe_workspace_cleanup_path, expanded_path}}
    end
  end

  defp ensure_cleanup_target_matches_registration(
         normalized_path,
         expanded_path,
         %{issue_id: issue_id, root: root, token: token},
         %{issue_id: issue_id, root: root, token: token}
       ) do
    ensure_registered_cleanup_target_matches_path(normalized_path, expanded_path, root, issue_id)
  end

  defp ensure_cleanup_target_matches_registration(
         normalized_path,
         _expanded_path,
         _registration,
         _metadata
       ) do
    {:error, {:unsafe_workspace_cleanup_path, normalized_path}}
  end

  defp ensure_cleanup_target_matches_root_registration(
         normalized_path,
         expanded_path,
         %{issue_id: issue_id, root: root, token: token}
       )
       when is_binary(token) and token != "" do
    with {:ok, %{token: ^token}} <- read_workspace_root_registration(root) do
      ensure_cleanup_target_matches_path(normalized_path, expanded_path, root, issue_id)
    else
      :missing ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}

      {:error, _reason} ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}
    end
  end

  defp ensure_cleanup_target_matches_root_registration(
         normalized_path,
         _expanded_path,
         _metadata
       ) do
    {:error, {:unsafe_workspace_cleanup_path, normalized_path}}
  end

  defp ensure_registered_cleanup_target_matches_path(
         normalized_path,
         expanded_path,
         root,
         issue_id
       ) do
    with {:ok, expected_path} <- workspace_path(root, issue_id),
         :ok <- ensure_path_within_root(expanded_path, root),
         true <- Path.expand(expected_path) == expanded_path do
      :ok
    else
      false ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}

      {:error, {:workspace_path_outside_root, _path, _root}} ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_cleanup_target_matches_path(normalized_path, expanded_path, root, issue_id) do
    with :ok <- ensure_trusted_workspace_root(root, normalized_path),
         {:ok, expected_path} <- workspace_path(root, issue_id),
         :ok <- ensure_path_within_root(expanded_path, root),
         true <- Path.expand(expected_path) == expanded_path do
      :ok
    else
      false ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}

      {:error, {:workspace_path_outside_root, _path, _root}} ->
        {:error, {:unsafe_workspace_cleanup_path, normalized_path}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_trusted_workspace_root(root, normalized_path) do
    if trusted_workspace_root?(root) do
      :ok
    else
      {:error, {:unsafe_workspace_cleanup_path, normalized_path}}
    end
  end

  defp trusted_workspace_root?(root) do
    expanded_root = Path.expand(root)

    path_within_or_equal_root?(expanded_root, workspace_base()) or
      Enum.any?(workspace_allowed_roots(), &(Path.expand(&1) == expanded_root))
  end

  defp path_within_or_equal_root?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    root_prefix = expanded_root <> "/"

    expanded_path == expanded_root or String.starts_with?(expanded_path, root_prefix)
  end
end
