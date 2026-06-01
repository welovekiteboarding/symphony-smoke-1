defmodule Symphony1.Project.Bootstrap do
  alias Symphony1.{MergeRuntime, Runtime}
  alias Symphony1.Project.{ProductScaffold, Scaffold, Setup}

  @spec run(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(attrs, opts \\ []) do
    scaffold_runner = Keyword.get(opts, :scaffold_runner, scaffold_runner(attrs))
    setup_runner = Keyword.get(opts, :setup_runner, &run_setup_in_project/1)
    runtime_runner = Keyword.get(opts, :runtime_runner, &Runtime.run/1)
    merge_runtime_runner = Keyword.get(opts, :merge_runtime_runner, &MergeRuntime.run/1)

    scaffold_attrs =
      attrs
      |> Map.put(:github, true)
      |> Map.put(:private, Map.get(attrs, :private, false))

    with {:ok, %{project_path: project_path}} <- scaffold_runner.(scaffold_attrs),
         {:ok, setup_state} <- setup_runner.(project_path),
         {:ok, runtime_result} <- runtime_runner.(cwd: project_path, once: true),
         {:ok, proof_result} <-
           complete_bootstrap(attrs, project_path, runtime_result, merge_runtime_runner) do
      {:ok,
       proof_result
       |> Map.merge(%{
         github_repo: "#{Map.fetch!(attrs, :github_owner)}/#{Map.fetch!(attrs, :project_name)}",
         project_path: project_path,
         proof_issue_identifier: get_in(setup_state, ["proof_issue", "identifier"])
       })}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_setup_in_project(project_path) do
    File.cd!(project_path, fn -> Setup.run() end)
  end

  defp scaffold_runner(%{template: "product-empty"}), do: &ProductScaffold.generate/1
  defp scaffold_runner(_attrs), do: &Scaffold.generate/1

  defp complete_bootstrap(
         %{template: "product-empty"},
         _project_path,
         runtime_result,
         _merge_runtime_runner
       ) do
    with {:ok, url} <- review_pull_request_url(runtime_result) do
      {:ok, %{proof_pull_request_url: url, proof_terminal_state: :human_review}}
    end
  end

  defp complete_bootstrap(_attrs, project_path, _runtime_result, merge_runtime_runner) do
    with {:ok, merge_result} <- merge_runtime_runner.(cwd: project_path, once: true),
         {:ok, merged_pr_url} <- review_pull_request_url(merge_result) do
      {:ok,
       %{
         merged_pr_url: merged_pr_url,
         proof_pull_request_url: merged_pr_url,
         proof_terminal_state: :merged
       }}
    end
  end

  defp review_pull_request_url(%{results: [%{pull_request: %{url: url}} | _rest]}), do: {:ok, url}
  defp review_pull_request_url(_result), do: {:error, :merge_result_missing_pull_request}
end
