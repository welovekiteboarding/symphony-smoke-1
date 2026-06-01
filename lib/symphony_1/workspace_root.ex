defmodule Symphony1.WorkspaceRoot do
  @moduledoc """
  Resolves worker workspace roots without letting tool discovery escape into repo parents.

  Relative workflow roots are intentionally placed under a sterile OS temp base instead
  of under the product repo. Absolute workflow roots remain explicit operator overrides.
  """

  @default_relative_root "./tmp/workspaces"
  @workspace_base_dir "symphony-workspaces"

  @spec resolve(String.t(), map() | nil, map() | nil) :: String.t()
  def resolve(repo_root, workflow, intent) do
    workflow_root = get_in(workflow || %{}, ["workspace", "root"]) || @default_relative_root

    case Path.type(workflow_root) do
      :absolute ->
        Path.expand(workflow_root)

      _relative ->
        Path.join([
          sterile_base(),
          project_slug(intent, repo_root),
          normalize_relative_root(workflow_root)
        ])
    end
  end

  defp sterile_base do
    :symphony_1
    |> Application.get_env(:workspace_base, Path.join(System.tmp_dir!(), @workspace_base_dir))
    |> Path.expand()
  end

  defp project_slug(intent, repo_root) do
    candidate =
      get_in(intent || %{}, ["github", "repo"]) ||
        get_in(intent || %{}, ["project", "name"]) ||
        Path.basename(repo_root)

    candidate
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "repo"
      slug -> slug
    end
  end

  defp normalize_relative_root(root) do
    root
    |> Path.split()
    |> Enum.reject(&(&1 in [".", ""]))
    |> case do
      [] -> "workspaces"
      parts -> Path.join(parts)
    end
  end
end
