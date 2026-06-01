defmodule Symphony1.Core.GitHub do
  require Logger

  alias Symphony1.Observability.Recorder

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec find_pull_request_by_branch(map(), command_runner()) ::
          {:ok, map()} | :none | {:error, term()}
  def find_pull_request_by_branch(attrs, runner \\ &System.cmd/3) do
    args =
      [
        "pr",
        "list"
      ] ++
        repo_args(attrs) ++
        [
          "--head",
          attrs.branch,
          "--state",
          Map.get(attrs, :state, "open"),
          "--json",
          "url,title,state,headRefName,baseRefName"
        ]

    case runner.("gh", args, command_options(attrs.cwd)) do
      {output, 0} ->
        output
        |> Jason.decode()
        |> decode_pull_request(attrs)

      {output, exit_status} ->
        {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  @spec reopen_pull_request(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def reopen_pull_request(%{url: url} = pull_request, runner \\ &System.cmd/3) do
    args = ["pr", "reopen", url]
    started_at = System.monotonic_time(:millisecond)

    record_issue_event(pull_request, "pull_request_reopen_started", "github",
      workspace_path: pull_request.cwd,
      branch: Map.get(pull_request, :branch),
      base_branch: Map.get(pull_request, :base_branch),
      pull_request_url: pull_request.url
    )

    case runner.("gh", args, command_options(pull_request.cwd)) do
      {_output, 0} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        reopened_pull_request = %{pull_request | status: :open}

        record_issue_event(reopened_pull_request, "pull_request_reopened", "github",
          workspace_path: reopened_pull_request.cwd,
          branch: Map.get(reopened_pull_request, :branch),
          base_branch: Map.get(reopened_pull_request, :base_branch),
          pull_request_url: reopened_pull_request.url,
          elapsed_ms: elapsed_ms
        )

        {:ok, reopened_pull_request}

      {output, exit_status} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        record_issue_event(pull_request, "pull_request_reopen_failed", "github",
          workspace_path: pull_request.cwd,
          branch: Map.get(pull_request, :branch),
          base_branch: Map.get(pull_request, :base_branch),
          pull_request_url: pull_request.url,
          elapsed_ms: elapsed_ms,
          failure_reason: command_failure_reason("gh", exit_status, output)
        )

        {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  @spec open_pull_request(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def open_pull_request(attrs, runner \\ &System.cmd/3) do
    args = [
      "pr",
      "create",
      "--base",
      attrs.base_branch,
      "--head",
      attrs.branch,
      "--title",
      attrs.title,
      "--body",
      attrs.body
    ]

    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "symphony.github: pr_create start issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} base=#{attrs.base_branch} cwd=#{attrs.cwd}"
    )

    record_issue_event(attrs, "pull_request_create_started", "github",
      workspace_path: attrs.cwd,
      branch: attrs.branch,
      base_branch: attrs.base_branch
    )

    case runner.("gh", args, command_options(attrs.cwd)) do
      {output, 0} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Logger.info(
          "symphony.github: pr_create finish issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} exit=0 elapsed_ms=#{elapsed_ms} output=#{inspect(String.trim(output))}"
        )

        {:ok,
         %{
           base_branch: attrs.base_branch,
           body: attrs.body,
           branch: attrs.branch,
           cwd: attrs.cwd,
           repo: attrs.repo,
           status: :open,
           title: attrs.title,
           url: String.trim(output)
         }}
        |> then(fn {:ok, pull_request} = result ->
          record_issue_event(attrs, "pull_request_created", "github",
            workspace_path: attrs.cwd,
            branch: attrs.branch,
            base_branch: attrs.base_branch,
            pull_request_url: pull_request.url,
            elapsed_ms: elapsed_ms
          )

          result
        end)

      {output, exit_status} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Logger.warning(
          "symphony.github: pr_create finish issue=#{issue_identifier(attrs)} repo=#{inspect(attrs.repo)} branch=#{attrs.branch} exit=#{exit_status} elapsed_ms=#{elapsed_ms} output=#{inspect(String.trim(output))}"
        )

        record_issue_event(attrs, "pull_request_create_failed", "github",
          workspace_path: attrs.cwd,
          branch: attrs.branch,
          base_branch: attrs.base_branch,
          elapsed_ms: elapsed_ms,
          failure_reason: command_failure_reason("gh", exit_status, output)
        )

        {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
    end
  end

  @spec merge_pull_request(map(), command_runner()) :: {:ok, map()} | {:error, term()}
  def merge_pull_request(pull_request, runner \\ &System.cmd/3)

  def merge_pull_request(%{status: :open} = pull_request, runner) do
    started_at = System.monotonic_time(:millisecond)

    record_issue_event(pull_request, "pull_request_merge_started", "github",
      workspace_path: pull_request.cwd,
      branch: Map.get(pull_request, :branch),
      base_branch: Map.get(pull_request, :base_branch),
      pull_request_url: pull_request.url
    )

    with {:ok, merge_flag} <- merge_flag(pull_request) do
      args = ["pr", "merge", pull_request.url, merge_flag]

      case runner.("gh", args, command_options(pull_request.cwd)) do
        {_output, 0} ->
          elapsed_ms = System.monotonic_time(:millisecond) - started_at
          merged_pull_request = %{pull_request | status: :merged}

          record_issue_event(merged_pull_request, "pull_request_merged", "github",
            workspace_path: merged_pull_request.cwd,
            branch: Map.get(merged_pull_request, :branch),
            base_branch: Map.get(merged_pull_request, :base_branch),
            pull_request_url: merged_pull_request.url,
            elapsed_ms: elapsed_ms
          )

          {:ok, merged_pull_request}

        {output, exit_status} ->
          elapsed_ms = System.monotonic_time(:millisecond) - started_at

          record_issue_event(pull_request, "pull_request_merge_failed", "github",
            workspace_path: pull_request.cwd,
            branch: Map.get(pull_request, :branch),
            base_branch: Map.get(pull_request, :base_branch),
            pull_request_url: pull_request.url,
            elapsed_ms: elapsed_ms,
            failure_reason: command_failure_reason("gh", exit_status, output)
          )

          {:error, {:command_failed, "gh", exit_status, String.trim(output)}}
      end
    else
      {:error, reason} ->
        record_issue_event(pull_request, "pull_request_merge_failed", "github",
          workspace_path: pull_request.cwd,
          branch: Map.get(pull_request, :branch),
          base_branch: Map.get(pull_request, :base_branch),
          pull_request_url: pull_request.url,
          failure_reason: format_merge_strategy_failure(reason)
        )

        {:error, reason}
    end
  end

  def merge_pull_request(pull_request, _runner) do
    record_issue_event(pull_request, "pull_request_merge_failed", "github",
      workspace_path: Map.get(pull_request, :cwd),
      branch: Map.get(pull_request, :branch),
      base_branch: Map.get(pull_request, :base_branch),
      pull_request_url: Map.get(pull_request, :url),
      failure_reason: "invalid_pull_request_status: #{inspect(pull_request.status)}"
    )

    {:error, {:invalid_pull_request_status, pull_request.status}}
  end

  defp record_issue_event(attrs, event, phase, details) do
    case observability_root(attrs) do
      nil ->
        :ok

      root ->
        Recorder.record(root, event,
          issue_identifier: issue_identifier(attrs),
          graph_task_id: Map.get(attrs, :graph_task_id),
          phase: phase,
          severity: severity_for_event(event),
          details: details
        )
    end
  end

  defp observability_root(attrs) do
    Map.get(attrs, :observability_root) || Map.get(attrs, :repo_root)
  end

  defp severity_for_event(event) do
    if String.ends_with?(event, "_failed"), do: "warning", else: "info"
  end

  defp command_failure_reason(command, exit_status, output) do
    "#{command} exit #{exit_status}: #{String.trim(output)}"
  end

  defp format_merge_strategy_failure({:invalid_merge_strategy, strategy}) do
    "invalid_merge_strategy: #{inspect(strategy)}"
  end

  defp format_merge_strategy_failure(reason), do: inspect(reason)

  @spec refresh_base_branch(map(), command_runner()) :: :ok | {:error, term()}
  def refresh_base_branch(attrs, runner \\ &System.cmd/3) do
    base_branch = Map.get(attrs, :base_branch, "main")
    cwd = Map.fetch!(attrs, :cwd)
    started_at = System.monotonic_time(:millisecond)

    Logger.info(
      "symphony.github: refresh_base start repo=#{inspect(Map.get(attrs, :repo))} base=#{base_branch} cwd=#{cwd}"
    )

    with {:ok, current_branch} <- current_branch(cwd, runner),
         :ok <- ensure_base_branch(current_branch, base_branch),
         :ok <- git_fetch_base(cwd, base_branch, runner),
         :ok <- git_fast_forward(cwd, runner) do
      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      Logger.info(
        "symphony.github: refresh_base finish repo=#{inspect(Map.get(attrs, :repo))} base=#{base_branch} exit=0 elapsed_ms=#{elapsed_ms}"
      )

      :ok
    else
      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at

        Logger.warning(
          "symphony.github: refresh_base finish repo=#{inspect(Map.get(attrs, :repo))} base=#{base_branch} exit=1 elapsed_ms=#{elapsed_ms} reason=#{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp decode_pull_request({:ok, pull_requests}, attrs) when is_list(pull_requests) do
    pull_requests
    |> reusable_pull_request()
    |> case do
      nil -> :none
      pull_request -> decode_pull_request(pull_request, attrs)
    end
  end

  defp decode_pull_request(%{} = pull_request, attrs) do
    {:ok,
     %{
       base_branch: pull_request["baseRefName"],
       branch: pull_request["headRefName"] || attrs.branch,
       cwd: attrs.cwd,
       repo: attrs.repo,
       status: normalize_pull_request_status(pull_request["state"]),
       title: pull_request["title"],
       url: pull_request["url"]
     }}
  end

  defp decode_pull_request({:error, reason}, _attrs), do: {:error, reason}

  defp reusable_pull_request(pull_requests) do
    Enum.find(pull_requests, &(normalize_pull_request_status(&1["state"]) == :open)) ||
      Enum.find(pull_requests, &(normalize_pull_request_status(&1["state"]) == :closed))
  end

  defp merge_flag(pull_request) do
    pull_request
    |> Map.get(:merge_strategy)
    |> normalize_merge_strategy()
    |> case do
      {:ok, strategy} -> {:ok, "--" <> strategy}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_merge_strategy(nil), do: {:ok, "merge"}
  defp normalize_merge_strategy(:merge), do: {:ok, "merge"}
  defp normalize_merge_strategy(:squash), do: {:ok, "squash"}
  defp normalize_merge_strategy(:rebase), do: {:ok, "rebase"}
  defp normalize_merge_strategy("merge"), do: {:ok, "merge"}
  defp normalize_merge_strategy("squash"), do: {:ok, "squash"}
  defp normalize_merge_strategy("rebase"), do: {:ok, "rebase"}

  defp normalize_merge_strategy(strategy) when is_binary(strategy) do
    case strategy |> String.trim() |> String.downcase() do
      "merge" -> {:ok, "merge"}
      "squash" -> {:ok, "squash"}
      "rebase" -> {:ok, "rebase"}
      other -> {:error, {:invalid_merge_strategy, other}}
    end
  end

  defp normalize_merge_strategy(strategy), do: {:error, {:invalid_merge_strategy, strategy}}

  defp normalize_pull_request_status("OPEN"), do: :open
  defp normalize_pull_request_status("MERGED"), do: :merged
  defp normalize_pull_request_status("CLOSED"), do: :closed
  defp normalize_pull_request_status(_status), do: :unknown

  defp repo_args(%{repo: repo}) when is_binary(repo), do: ["--repo", repo]
  defp repo_args(_attrs), do: []

  defp current_branch(cwd, runner) do
    case runner.("git", ["rev-parse", "--abbrev-ref", "HEAD"], command_options(cwd)) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp ensure_base_branch(base_branch, base_branch), do: :ok

  defp ensure_base_branch(current_branch, base_branch) do
    {:error, {:wrong_base_branch, current_branch, base_branch}}
  end

  defp git_fetch_base(cwd, base_branch, runner) do
    case runner.("git", ["fetch", "origin", base_branch], command_options(cwd)) do
      {_output, 0} ->
        :ok

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp git_fast_forward(cwd, runner) do
    case runner.("git", ["merge", "--ff-only", "FETCH_HEAD"], command_options(cwd)) do
      {_output, 0} ->
        :ok

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end

  defp issue_identifier(%{issue_identifier: issue_identifier}) when is_binary(issue_identifier),
    do: issue_identifier

  defp issue_identifier(%{issue: %{identifier: issue_identifier}})
       when is_binary(issue_identifier), do: issue_identifier

  defp issue_identifier(_attrs), do: "unknown-issue"

  defp command_options(cwd) do
    [cd: cwd, stderr_to_stdout: true]
  end
end
