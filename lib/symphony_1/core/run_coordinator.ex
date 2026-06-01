defmodule Symphony1.Core.RunCoordinator do
  require Logger

  alias Symphony1.Core.{GitHub, Linear, Tracker, Worker, Workspace}
  alias Symphony1.Observability.Recorder
  alias Symphony1.Planning.Graph
  alias Symphony1.Project.RepoAdapter

  @default_finalization_repair_attempts 1

  @spec normalize_run_attrs(map()) :: map()
  def normalize_run_attrs(attrs) do
    base_branch =
      Workspace.resolve_base_branch(Map.get(attrs, :source_repo), Map.get(attrs, :base_branch))

    Map.put(attrs, :base_branch, base_branch)
  end

  @spec run_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_issue(
        %{
          issues: issues,
          workspace_root: workspace_root,
          workflow_path: workflow_path
        } = attrs
      ) do
    attrs = normalize_run_attrs(attrs)

    with {:ok, issue} <- Tracker.poll_eligible_issue(issues),
         {:ok, in_progress_issue} <- Tracker.transition_issue(issue, "In Progress") do
      build_claimed_run(in_progress_issue, attrs, workspace_root, workflow_path)
    end
  end

  def run_issue(
        %{
          linear_config: linear_config,
          workspace_root: workspace_root,
          workflow_path: workflow_path
        } = attrs
      ) do
    attrs = normalize_run_attrs(attrs)
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)

    allowed_issue_identifiers = Map.get(attrs, :allowed_issue_identifiers)

    with {:ok, issue} <-
           Linear.poll_eligible_issue(linear_config, allowed_issue_identifiers, requester),
         {:ok, in_progress_issue} <-
           Linear.transition_issue(issue, "In Progress", linear_config, requester) do
      build_claimed_run(in_progress_issue, attrs, workspace_root, workflow_path)
    end
  end

  @spec run_full_issue(map()) :: {:ok, map()} | :none | {:error, term()}
  def run_full_issue(attrs) do
    attrs = normalize_run_attrs(attrs)

    with {:ok, run} <- run_issue(attrs) do
      finish_claimed_issue(run, attrs)
    else
      :none ->
        :none

      {:error, {:workspace_creation_failed, issue, workspace_path, reason}} ->
        recover_workspace_creation_failure(issue, attrs, workspace_path, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec recover_workspace_creation_failure(map(), map(), String.t(), term()) ::
          {:error, term()}
  def recover_workspace_creation_failure(issue, attrs, workspace_path, reason) do
    graph_task_id = graph_task_id_for_issue(issue, attrs)

    recover_failed_run(
      issue,
      attrs
      |> Map.put(:workspace, workspace_path)
      |> Map.put(:graph_task_id, graph_task_id),
      :workspace_creation,
      reason
    )
  end

  @spec finish_claimed_issue(map(), map()) :: {:ok, map()} | {:error, term()}
  def finish_claimed_issue(run, attrs) do
    attrs = normalize_run_attrs(attrs)
    github_runner = Map.get(attrs, :github_runner, &System.cmd/3)
    repo_finalizer = Map.get(attrs, :repo_finalizer, &RepoAdapter.finalize_workspace/2)
    progress_reporter = Map.get(attrs, :progress_reporter, fn _message -> :ok end)
    worker_adapter = Map.get(attrs, :worker, Worker)
    issue_started_at = now_ms()
    worker_started_at = now_ms()

    task_context = resolve_task_context(run.issue, attrs)
    attrs = Map.put(attrs, :task_context, task_context)
    run_event_details = issue_event_details(run.issue, attrs, workspace_path: run.workspace)

    Logger.info("symphony.coordinator: executing worker for #{run.issue.identifier}")
    progress_reporter.("Running Codex for #{run.issue.identifier}")

    record_issue_event(attrs, run.issue, "worker_execution_started", "worker", run_event_details)

    case execute_worker(run, attrs, worker_adapter) do
      {:ok, worker_result} ->
        worker_elapsed_ms = now_ms() - worker_started_at
        worker_elapsed = format_elapsed(worker_elapsed_ms)

        record_issue_event(
          attrs,
          run.issue,
          "worker_execution_completed",
          "worker",
          Map.merge(run_event_details, %{elapsed_ms: worker_elapsed_ms})
        )

        Logger.info(
          "symphony.coordinator: worker complete for #{run.issue.identifier}, finalizing"
        )

        progress_reporter.("Codex finished for #{run.issue.identifier} in #{worker_elapsed}")

        case transition_to_finalizing(run.issue, attrs) do
          {:ok, finalizing_issue} ->
            record_issue_event(
              attrs,
              finalizing_issue,
              "finalization_started",
              "finalization",
              run_event_details
            )

            Logger.info(
              "symphony.coordinator: #{finalizing_issue.identifier} transitioned to Finalizing"
            )

            progress_reporter.("Finalizing #{finalizing_issue.identifier}")

            case finalize_and_review(
                   %{run | issue: finalizing_issue},
                   attrs,
                   worker_result,
                   repo_finalizer,
                   github_runner,
                   worker_adapter,
                   progress_reporter,
                   issue_started_at
                 ) do
              result -> result
            end

          {:error, reason} ->
            record_issue_event(
              attrs,
              run.issue,
              "finalization_transition_failed",
              "finalization",
              Map.merge(run_event_details, %{failure_reason: format_failure_reason(reason)}),
              severity: "warning"
            )

            Logger.warning(
              "symphony.coordinator: Finalizing transition failed for #{run.issue.identifier}: #{inspect(reason)}"
            )

            recover_failed_run(
              run.issue,
              Map.put(attrs, :workspace, run.workspace),
              :finalizing_transition,
              reason
            )
        end

      {:error, reason} ->
        record_issue_event(
          attrs,
          run.issue,
          "worker_execution_failed",
          "worker",
          Map.merge(run_event_details, %{
            elapsed_ms: now_ms() - worker_started_at,
            failure_reason: format_failure_reason(reason)
          }),
          severity: "warning"
        )

        Logger.warning(
          "symphony.coordinator: worker failed for #{run.issue.identifier}: #{inspect(reason)}"
        )

        recover_failed_run(
          run.issue,
          Map.put(attrs, :workspace, run.workspace),
          :worker_execution,
          reason
        )
    end
  end

  @spec recover_timed_out_issue(map(), map()) :: {:error, term()}
  def recover_timed_out_issue(issue, attrs) do
    recover_failed_run(issue, attrs, :task_timeout, :task_timeout)
  end

  defp finalize_and_review(
         run,
         attrs,
         worker_result,
         repo_finalizer,
         github_runner,
         worker_adapter,
         progress_reporter,
         issue_started_at
       ) do
    case finalize_run(
           %{
             base_branch: attrs.base_branch,
             body: attrs.body,
             branch: Map.get(attrs, :branch, default_branch(run.issue.identifier)),
             issue: run.issue,
             observability_root: observability_root(attrs),
             project_type: Map.get(attrs, :project_type),
             repo: attrs.repo,
             reuse_pull_request: continuation_rework?(run.issue, Map.get(attrs, :task_context)),
             task_context: Map.get(attrs, :task_context),
             title: attrs.title,
             workspace: run.workspace
           },
           repo_finalizer,
           github_runner
         ) do
      {:ok, review} ->
        finalization_branch =
          Map.get(review.finalization || %{}, :branch) ||
            Map.get(review.pull_request, :branch) ||
            Map.get(attrs, :branch, default_branch(review.issue.identifier))

        record_issue_event(
          attrs,
          review.issue,
          "finalization_completed",
          "finalization",
          issue_event_details(review.issue, attrs,
            workspace_path: review.workspace,
            branch: finalization_branch,
            pull_request_url: review.pull_request.url,
            elapsed_ms: now_ms() - issue_started_at
          )
        )

        progress_reporter.("Opening PR for #{review.issue.identifier}")

        Logger.info(
          "symphony.coordinator: PR opened for #{review.issue.identifier} (#{review.pull_request.url})"
        )

        progress_reporter.(
          "Opened PR for #{review.issue.identifier} (#{review.pull_request.url})"
        )

        case transition_to_review(review.issue, review.pull_request, attrs) do
          {:ok, issue} ->
            total_elapsed_ms = now_ms() - issue_started_at
            total_elapsed = format_elapsed(total_elapsed_ms)

            record_issue_event(
              attrs,
              issue,
              "review_transition_completed",
              "review",
              issue_event_details(issue, attrs,
                workspace_path: review.workspace,
                branch: review.pull_request.branch,
                pull_request_url: review.pull_request.url,
                elapsed_ms: total_elapsed_ms
              )
            )

            Logger.info("symphony.coordinator: #{issue.identifier} transitioned to Human Review")

            progress_reporter.(
              "Completed #{issue.identifier} -> Human Review (#{review.pull_request.url}) in #{total_elapsed}"
            )

            {:ok,
             %{
               finalization: review.finalization,
               issue: issue,
               pull_request: review.pull_request,
               worker_result: worker_result,
               workspace: review.workspace
             }}

          {:error, reason} ->
            record_issue_event(
              attrs,
              review.issue,
              "review_transition_failed",
              "review",
              issue_event_details(review.issue, attrs,
                workspace_path: review.workspace,
                branch: review.pull_request.branch,
                pull_request_url: review.pull_request.url,
                failure_reason: format_failure_reason(reason)
              ),
              severity: "warning"
            )

            Logger.warning(
              "symphony.coordinator: review transition failed for #{review.issue.identifier}: #{inspect(reason)}"
            )

            recover_failed_run(
              review.issue,
              Map.put(attrs, :workspace, review.workspace),
              :review_transition,
              reason
            )
        end

      {:error, reason} ->
        record_issue_event(
          attrs,
          run.issue,
          "finalization_failed",
          "finalization",
          issue_event_details(run.issue, attrs,
            workspace_path: run.workspace,
            failure_reason: format_failure_reason(reason)
          ),
          severity: "warning"
        )

        Logger.warning(
          "symphony.coordinator: finalization failed for #{run.issue.identifier}: #{inspect(reason)}"
        )

        case repair_finalization(run, attrs, reason, worker_adapter, progress_reporter) do
          {:ok, repair_result, attrs} ->
            finalize_and_review(
              run,
              attrs,
              merge_worker_results(worker_result, repair_result),
              repo_finalizer,
              github_runner,
              worker_adapter,
              progress_reporter,
              issue_started_at
            )

          {:error, :repair_not_available} ->
            recover_failed_run(
              run.issue,
              Map.put(attrs, :workspace, run.workspace),
              :review_preparation,
              reason
            )

          {:error, repair_reason} ->
            recover_failed_run(
              run.issue,
              Map.put(attrs, :workspace, run.workspace),
              :review_preparation,
              {:finalization_failed_after_repair, reason, repair_reason}
            )
        end
    end
  end

  @spec open_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def open_review(%{workspace: workspace} = attrs, github_runner \\ &System.cmd/3) do
    title = Map.get(attrs, :title, default_pr_title(attrs.issue))
    body = Map.get(attrs, :body, default_pr_body(attrs.issue))

    with {:ok, branch} <- current_branch(workspace),
         {:ok, pull_request} <-
           find_or_open_pull_request(attrs, branch, title, body, github_runner) do
      {:ok,
       %{
         issue: attrs.issue,
         finalization: Map.get(attrs, :finalization),
         pull_request: pull_request,
         workspace: workspace
       }}
    end
  end

  defp find_or_open_pull_request(attrs, branch, title, body, github_runner) do
    reuse_pull_request? = Map.get(attrs, :reuse_pull_request, false)

    pr_attrs = %{
      base_branch: attrs.base_branch,
      body: body,
      branch: branch,
      cwd: attrs.workspace,
      graph_task_id: graph_task_id_for_issue(attrs.issue, attrs),
      issue_identifier: attrs.issue.identifier,
      observability_root: observability_root(attrs),
      repo: attrs.repo,
      title: title
    }

    case resolve_existing_pull_request(pr_attrs, github_runner) do
      {:ok, pull_request} ->
        {:ok, pull_request}

      :none ->
        create_pull_request_with_lookup_recovery(pr_attrs, github_runner)

      {:error, reason} when reuse_pull_request? ->
        {:error, reason}

      {:error, _reason} ->
        create_pull_request_with_lookup_recovery(pr_attrs, github_runner)
    end
  end

  defp resolve_existing_pull_request(pr_attrs, github_runner) do
    case find_any_pull_request_by_branch(pr_attrs, github_runner) do
      {:ok, %{status: :closed} = pull_request} ->
        reopen_pull_request_for_issue(pr_attrs, pull_request, github_runner)

      {:ok, pull_request} ->
        {:ok, record_reused_pull_request(pr_attrs, pull_request)}

      :none ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_pull_request_with_lookup_recovery(pr_attrs, github_runner) do
    case GitHub.open_pull_request(pr_attrs, github_runner) do
      {:ok, pull_request} ->
        {:ok, pull_request}

      {:error, {:command_failed, "gh", _exit_status, _output}} = error ->
        case resolve_existing_pull_request(pr_attrs, github_runner) do
          {:ok, pull_request} -> {:ok, pull_request}
          :none -> error
          {:error, _reason} -> error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp find_any_pull_request_by_branch(pr_attrs, github_runner) do
    pr_attrs
    |> Map.put(:state, "all")
    |> GitHub.find_pull_request_by_branch(github_runner)
  end

  defp reopen_pull_request_for_issue(pr_attrs, pull_request, github_runner) do
    pull_request
    |> Map.merge(%{
      graph_task_id: pr_attrs.graph_task_id,
      issue_identifier: pr_attrs.issue_identifier,
      observability_root: pr_attrs.observability_root
    })
    |> GitHub.reopen_pull_request(github_runner)
  end

  defp record_reused_pull_request(pr_attrs, pull_request) do
    case pr_attrs.observability_root do
      nil ->
        pull_request

      root ->
        Recorder.record(root, "pull_request_reused",
          issue_identifier: pr_attrs.issue_identifier,
          graph_task_id: pr_attrs.graph_task_id,
          phase: "github",
          details: %{
            workspace_path: pr_attrs.cwd,
            branch: Map.get(pull_request, :branch, pr_attrs.branch),
            base_branch: Map.get(pull_request, :base_branch, pr_attrs.base_branch),
            pull_request_url: pull_request.url
          }
        )

        pull_request
    end
  end

  @spec finalize_run(map(), function(), GitHub.command_runner()) ::
          {:ok, map()} | {:error, term()}
  def finalize_run(
        attrs,
        repo_boundary \\ &RepoAdapter.finalize_workspace/2,
        github_runner \\ &System.cmd/3
      )

  def finalize_run(attrs, validation_runner, github_runner)
      when is_function(validation_runner, 3) do
    repo_boundary = fn repo_attrs, _default_runner ->
      RepoAdapter.finalize_workspace(repo_attrs, validation_runner)
    end

    finalize_run(attrs, repo_boundary, github_runner)
  end

  def finalize_run(attrs, repo_boundary, github_runner) when is_function(repo_boundary, 2) do
    with {:ok, finalization} <- repo_boundary.(attrs, &System.cmd/3),
         {:ok, review} <- open_review(Map.put(attrs, :finalization, finalization), github_runner) do
      {:ok, review}
    end
  end

  @spec merge_review(map(), GitHub.command_runner()) :: {:ok, map()} | {:error, term()}
  def merge_review(attrs, github_runner \\ &System.cmd/3) do
    cleanup = Map.get(attrs, :cleanup, &Workspace.cleanup/1)
    Logger.info("symphony.coordinator: starting merge for #{attrs.issue.identifier}")

    record_issue_event(
      attrs,
      attrs.issue,
      "merge_started",
      "merge",
      issue_event_details(attrs.issue, attrs,
        workspace_path: attrs.workspace,
        branch: Map.get(attrs.pull_request, :branch),
        base_branch: Map.get(attrs.pull_request, :base_branch),
        pull_request_url: Map.get(attrs.pull_request, :url)
      )
    )

    with {:ok, merging_issue, pull_request} <- merge_pull_request(attrs, github_runner),
         {:ok, done_issue} <- transition_to_done(merging_issue, attrs),
         :ok <- cleanup_workspace(attrs, cleanup) do
      record_issue_event(
        attrs,
        done_issue,
        "merge_completed",
        "merge",
        issue_event_details(done_issue, attrs,
          workspace_path: attrs.workspace,
          branch: Map.get(pull_request, :branch),
          base_branch: Map.get(pull_request, :base_branch),
          pull_request_url: Map.get(pull_request, :url)
        )
      )

      Logger.info("symphony.coordinator: merge complete for #{done_issue.identifier} -> Done")

      {:ok,
       %{
         issue: done_issue,
         pull_request: pull_request,
         workspace: attrs.workspace
       }}
    else
      {:error, reason} = error ->
        record_issue_event(
          attrs,
          attrs.issue,
          "merge_failed",
          "merge",
          issue_event_details(attrs.issue, attrs,
            workspace_path: attrs.workspace,
            branch: Map.get(attrs.pull_request, :branch),
            base_branch: Map.get(attrs.pull_request, :base_branch),
            pull_request_url: Map.get(attrs.pull_request, :url),
            failure_reason: format_failure_reason(reason)
          ),
          severity: "warning"
        )

        error
    end
  end

  defp merge_pull_request(
         %{issue: issue, pull_request: %{status: :merged} = pull_request},
         _github_runner
       ) do
    {:ok, issue, pull_request}
  end

  defp merge_pull_request(%{issue: issue, pull_request: pull_request} = attrs, github_runner) do
    with {:ok, merging_issue} <- transition_to_merging(issue, attrs),
         {:ok, merged_pull_request} <-
           GitHub.merge_pull_request(
             Map.merge(pull_request, %{
               graph_task_id: graph_task_id_for_issue(issue, attrs),
               issue_identifier: issue.identifier,
               merge_strategy: Map.get(attrs, :merge_strategy),
               observability_root: observability_root(attrs)
             }),
             github_runner
           ) do
      {:ok, merging_issue, merged_pull_request}
    end
  end

  defp build_claimed_run(issue, attrs, workspace_root, workflow_path) do
    branch = Map.get(attrs, :branch, default_branch(issue.identifier))
    workspace_path = Workspace.path_for_issue(workspace_root, issue.identifier)

    record_issue_event(
      attrs,
      issue,
      "workspace_creation_started",
      "workspace",
      issue_event_details(issue, attrs, branch: branch, workspace_path: workspace_path)
    )

    case Workspace.create(%{
           base_branch: attrs.base_branch,
           branch: branch,
           issue_id: issue.identifier,
           root: workspace_root,
           source_repo: Map.get(attrs, :source_repo)
         }) do
      {:ok, workspace} ->
        worker =
          Worker.local_run_spec(%{
            workspace: workspace,
            workflow_path: workflow_path
          })

        record_issue_event(
          attrs,
          issue,
          "workspace_created",
          "workspace",
          issue_event_details(issue, attrs, branch: branch, workspace_path: workspace)
        )

        {:ok, %{issue: issue, workspace: workspace, worker: worker}}

      {:error, reason} ->
        record_issue_event(
          attrs,
          issue,
          "workspace_creation_failed",
          "workspace",
          issue_event_details(issue, attrs,
            branch: branch,
            workspace_path: workspace_path,
            failure_reason: format_failure_reason(reason)
          ),
          severity: "warning"
        )

        {:error, {:workspace_creation_failed, issue, workspace_path, reason}}
    end
  end

  defp execute_worker(run, attrs, worker_adapter) do
    prompt = issue_prompt(run.issue, attrs)
    worker_opts = [timeout_ms: Map.get(attrs, :worker_timeout_ms, 60_000)]

    worker_attrs = %{
      workspace: run.workspace,
      workflow_path: attrs.workflow_path
    }

    if worker_supports_run_once?(worker_adapter) do
      worker_run_once(worker_adapter, worker_attrs, prompt, worker_opts)
    else
      execute_worker_session(worker_adapter, worker_attrs, prompt, worker_opts)
    end
  end

  defp execute_worker_with_prompt(run, attrs, worker_adapter, prompt) do
    worker_opts = [timeout_ms: Map.get(attrs, :worker_timeout_ms, 60_000)]

    worker_attrs = %{
      workspace: run.workspace,
      workflow_path: attrs.workflow_path
    }

    if worker_supports_run_once?(worker_adapter) do
      worker_run_once(worker_adapter, worker_attrs, prompt, worker_opts)
    else
      execute_worker_session(worker_adapter, worker_attrs, prompt, worker_opts)
    end
  end

  defp repair_finalization(run, attrs, reason, worker_adapter, progress_reporter) do
    remaining =
      Map.get(attrs, :finalization_repair_attempts, @default_finalization_repair_attempts)

    if remaining > 0 do
      record_issue_event(
        attrs,
        run.issue,
        "finalization_retry_started",
        "retry",
        issue_event_details(run.issue, attrs,
          workspace_path: run.workspace,
          failure_reason: format_failure_reason(reason)
        )
      )

      Logger.info(
        "symphony.coordinator: attempting finalization repair for #{run.issue.identifier} (remaining=#{remaining})"
      )

      progress_reporter.("Repairing #{run.issue.identifier} after finalization failure")

      prompt = finalization_repair_prompt(run.issue, attrs, reason)

      case execute_worker_with_prompt(run, attrs, worker_adapter, prompt) do
        {:ok, repair_result} ->
          record_issue_event(
            attrs,
            run.issue,
            "finalization_retry_completed",
            "retry",
            issue_event_details(run.issue, attrs, workspace_path: run.workspace)
          )

          {:ok, repair_result, Map.put(attrs, :finalization_repair_attempts, remaining - 1)}

        {:error, repair_reason} ->
          record_issue_event(
            attrs,
            run.issue,
            "finalization_retry_failed",
            "retry",
            issue_event_details(run.issue, attrs,
              workspace_path: run.workspace,
              failure_reason: format_failure_reason(repair_reason)
            ),
            severity: "warning"
          )

          {:error, {:repair_worker_failed, repair_reason}}
      end
    else
      {:error, :repair_not_available}
    end
  end

  defp finalization_repair_prompt(issue, attrs, reason) do
    sections = [
      "Linear issue #{issue.identifier}: #{Map.get(issue, :title, "")}",
      "Symphony finalization found a deterministic problem after your implementation.",
      "Finalization failure:\n#{format_failure_reason(reason)}",
      format_task_context(Map.get(attrs, :task_context)),
      """
      Repair contract:
      - Do not start over and do not create a new project from scratch.
      - Inspect the current workspace and fix the exact finalization failure.
      - When repairing documentation, derive package names, commands, routes, features, and setup instructions from actual repo files.
      - If documentation claims a dependency, tool, route, command, feature, or package, make the repo match it or correct the documentation.
      - If a manifest, lockfile, config, validation command, or generated artifact is inconsistent, update the smallest set of files needed.
      - Re-run only focused checks needed to confirm the repair.
      - Leave the workspace ready for Symphony finalization. Do not open a PR.
      """
    ]

    sections
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp merge_worker_results(worker_result, repair_result) do
    Map.merge(worker_result, %{
      repair_result: repair_result,
      repaired: true
    })
  end

  defp execute_worker_session(worker_adapter, worker_attrs, prompt, worker_opts) do
    with {:ok, session} <- worker_start(worker_adapter, worker_attrs) do
      result = worker_run_prompt(worker_adapter, session, prompt, worker_opts)
      stop_result = worker_stop(worker_adapter, session)

      case {result, stop_result} do
        {{:ok, worker_result}, :ok} -> {:ok, worker_result}
        {{:error, _reason} = error, :ok} -> error
        {{:ok, _worker_result}, {:error, reason}} -> {:error, {:worker_stop_failed, reason}}
        {{:error, _reason} = error, {:error, _stop_reason}} -> error
      end
    end
  end

  defp now_ms do
    System.monotonic_time(:millisecond)
  end

  defp format_elapsed(ms) when ms >= 1000 do
    "#{div(ms, 1000)}s"
  end

  defp format_elapsed(ms) do
    "#{ms}ms"
  end

  defp transition_to_finalizing(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Finalizing", linear_config, requester)
  end

  defp transition_to_finalizing(issue, _attrs) do
    Tracker.transition_issue(issue, "Finalizing")
  end

  defp transition_to_review(issue, pull_request, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)

    Linear.transition_issue(
      issue,
      "Human Review",
      %{"description" => review_description(issue, pull_request.url)},
      linear_config,
      requester
    )
  end

  defp transition_to_review(issue, _pull_request, _attrs) do
    Tracker.transition_issue(issue, "Human Review")
  end

  defp review_description(issue, pull_request_url) do
    pr_note = pull_request_note(pull_request_url)

    case Map.get(issue, :description) do
      nil ->
        pr_note

      "" ->
        pr_note

      description when is_binary(description) ->
        if String.contains?(description, pull_request_url) do
          description
        else
          description <> "\n\n" <> pr_note
        end
    end
  end

  defp pull_request_note(pull_request_url) do
    case Regex.run(~r{/pull/(\d+)$}, pull_request_url) do
      [_, number] -> "GitHub PR: ##{number}\n#{pull_request_url}"
      _ -> "GitHub PR:\n#{pull_request_url}"
    end
  end

  defp transition_to_merging(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Merging", linear_config, requester)
  end

  defp transition_to_merging(issue, _attrs) do
    Tracker.transition_issue(issue, "Merging")
  end

  defp transition_to_done(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Done", linear_config, requester)
  end

  defp transition_to_done(issue, _attrs) do
    Tracker.transition_issue(issue, "Done")
  end

  defp cleanup_workspace(%{workspace: workspace}, cleanup) do
    case cleanup.(workspace) do
      :ok -> :ok
      {:error, reason} -> {:error, {:workspace_cleanup_failed, workspace, reason}}
    end
  end

  defp cleanup_workspace(_attrs, _cleanup), do: :ok

  defp recover_failed_run(issue, attrs, stage, reason) do
    record_issue_event(
      attrs,
      issue,
      "recovery_started",
      "recovery",
      issue_event_details(issue, attrs, failure_reason: format_failure_reason(reason))
    )

    Logger.warning(
      "symphony.coordinator: recovering #{issue.identifier} to Rework (stage=#{stage})"
    )

    graph_writeback_result = persist_graph_failure(issue, attrs, stage, reason)

    case transition_to_rework(issue, attrs) do
      {:ok, recovered_issue} ->
        record_issue_event(
          attrs,
          recovered_issue,
          "recovery_completed",
          "recovery",
          issue_event_details(recovered_issue, attrs,
            failure_reason: format_failure_reason(reason)
          )
        )

        case graph_writeback_result do
          :ok ->
            {:error, {:run_failed, stage, recovered_issue, reason}}

          {:error, writeback_reason} ->
            {:error,
             {:run_failed, stage, recovered_issue, reason,
              {:graph_writeback_failed, writeback_reason}}}
        end

      {:error, recovery_reason} ->
        record_issue_event(
          attrs,
          issue,
          "recovery_failed",
          "recovery",
          issue_event_details(issue, attrs,
            failure_reason: format_failure_reason(recovery_reason)
          ),
          severity: "warning"
        )

        {:error, {:run_failed, stage, issue, reason, {:recovery_failed, recovery_reason}}}
    end
  end

  defp persist_graph_failure(issue, attrs, stage, reason) do
    graph = Map.get(attrs, :graph)
    graph_path = Map.get(attrs, :graph_path)

    if graph && graph_path do
      failure_context = %{
        stage: to_string(stage),
        reason: format_failure_reason(reason),
        category: classify_failure(stage)
      }

      case Graph.record_task_failure(graph, issue.identifier, failure_context) do
        {:ok, updated_graph} ->
          case Graph.write(updated_graph, graph_path) do
            :ok ->
              Logger.info(
                "symphony.coordinator: persisted failure context for #{issue.identifier} to #{graph_path}"
              )

              :ok

            {:error, write_reason} ->
              Logger.warning(
                "symphony.coordinator: failed to write graph after failure recording: #{inspect(write_reason)}"
              )

              {:error, write_reason}
          end

        :none ->
          Logger.info(
            "symphony.coordinator: no graph task found for #{issue.identifier}, skipping failure recording"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp format_failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_failure_reason(reason) when is_binary(reason), do: reason
  defp format_failure_reason({tag, detail}) when is_atom(tag), do: "#{tag}: #{inspect(detail)}"
  defp format_failure_reason(reason), do: inspect(reason)

  defp classify_failure(:worker_execution), do: "worker_execution"
  defp classify_failure(:workspace_creation), do: "workspace"
  defp classify_failure(:review_preparation), do: "validation"
  defp classify_failure(:review_transition), do: "review"
  defp classify_failure(:finalizing_transition), do: "finalization"
  defp classify_failure(:task_timeout), do: "timeout"

  defp transition_to_rework(issue, %{linear_config: linear_config} = attrs) do
    requester = Map.get(attrs, :linear_requester, &Linear.request/3)
    Linear.transition_issue(issue, "Rework", linear_config, requester)
  end

  defp transition_to_rework(issue, _attrs) do
    Tracker.transition_issue(issue, "Rework")
  end

  defp record_issue_event(attrs, issue, event, phase, details, opts \\ []) do
    case observability_root(attrs) do
      nil ->
        :ok

      root ->
        Recorder.record(root, event,
          issue_identifier: issue.identifier,
          graph_task_id: graph_task_id_for_issue(issue, attrs),
          phase: phase,
          severity: Keyword.get(opts, :severity, "info"),
          details: details
        )
    end
  end

  defp observability_root(attrs) do
    Map.get(attrs, :observability_root) || Map.get(attrs, :source_repo) ||
      Map.get(attrs, :repo_root)
  end

  defp issue_event_details(issue, attrs, overrides) do
    base =
      %{
        branch: Map.get(attrs, :branch, default_branch(issue.identifier)),
        base_branch: Map.get(attrs, :base_branch)
      }
      |> maybe_put_detail(:workspace_path, Map.get(attrs, :workspace))
      |> maybe_put_detail(:pull_request_url, get_in(attrs, [:pull_request, :url]))

    Enum.reduce(overrides, base, fn {key, value}, details ->
      maybe_put_detail(details, key, value)
    end)
  end

  defp maybe_put_detail(details, _key, nil), do: details
  defp maybe_put_detail(details, _key, ""), do: details
  defp maybe_put_detail(details, key, value), do: Map.put(details, key, value)

  defp graph_task_id_for_issue(issue, attrs) do
    attrs
    |> Map.get(:graph_task_id)
    |> normalize_graph_task_id()
    |> case do
      id when is_binary(id) ->
        id

      nil ->
        case Map.get(attrs, :task_context) do
          %Graph.Task{id: id} ->
            id

          _other ->
            graph = Map.get(attrs, :graph)

            if graph do
              case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
                {:ok, task} -> task.id
                :none -> nil
              end
            end
        end
    end
  end

  defp normalize_graph_task_id(nil), do: nil
  defp normalize_graph_task_id(""), do: nil
  defp normalize_graph_task_id(value), do: to_string(value)

  defp issue_prompt(issue, attrs) do
    task_context = Map.get(attrs, :task_context)

    sections = [
      "Linear issue #{issue.identifier}: #{Map.get(issue, :title, "")}",
      issue_description(Map.get(issue, :description)),
      format_task_context(task_context),
      rework_continuation_contract(issue, task_context),
      worker_execution_contract(task_context),
      Map.get(
        attrs,
        :issue_prompt,
        "Implement the issue and leave the workspace ready for review."
      )
    ]

    sections
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp issue_description(nil), do: nil
  defp issue_description(""), do: nil
  defp issue_description(description), do: "Description: #{description}"

  defp rework_continuation_contract(issue, task_context) do
    if continuation_rework?(issue, task_context) do
      """
      Rework continuation contract:
      - Continue the existing issue branch and workspace.
      - Do not restart from scratch, recreate the project, or discard existing implementation work.
      - Fix the recorded previous failure using the current files as the starting point.
      - Commit on top of the current issue branch.
      - Do not open a new PR; Symphony will reuse the existing pull request for this branch.
      """
      |> String.trim()
    end
  end

  defp worker_execution_contract(%Graph.Task{validation: %Graph.Validation{commands: commands}})
       when commands != [] do
    """
    Worker execution contract:
    - Implement the requested file and code changes before running validation commands.
    - Do not preflight package managers or diagnose validation tooling before implementation.
    - Treat validation commands as post-change checks, not as starting instructions.
    - Symphony finalization will run required validation commands after the worker returns.
    - Run focused checks while implementing, but do not spend the task window debugging the full validation suite.
    - If full validation fails late in the turn or exposes dependency/toolchain mismatch, capture the exact command and error, then return the implemented workspace so Symphony can finalize or retry with that evidence.
    - When introducing dependencies for any stack, choose stable mutually compatible releases, update the manifest and lockfile, and avoid unconstrained latest versions for tightly-coupled toolchains.
    - When writing documentation, derive package names, commands, routes, features, and setup instructions from the actual files you created or changed.
    - Do not document intended/planned dependencies or tools unless they are present in the manifest/config files in this workspace.
    - Before returning, compare README/setup docs against manifests and scripts so docs describe the implemented repo, not the imagined stack.
    - Do not hand off known vulnerable direct runtime/production dependencies when the ecosystem audit tool reports a non-breaking fix.
    - Dev/build-tool advisories are recorded but are not blocking unless the graph explicitly makes them part of the task's security or validation contract.
    """
    |> String.trim()
  end

  defp worker_execution_contract(_task_context), do: nil

  defp continuation_rework?(%{identifier: issue_identifier}, %Graph.Task{
         last_failure: %Graph.LastFailure{linear_issue_identifier: issue_identifier}
       }),
       do: true

  defp continuation_rework?(_issue, _task_context), do: false

  defp resolve_task_context(issue, attrs) do
    graph = Map.get(attrs, :graph)

    if graph do
      case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
        {:ok, task} ->
          Logger.info(
            "symphony.coordinator: resolved graph task #{task.id} for #{issue.identifier}"
          )

          task

        :none ->
          Logger.info("symphony.coordinator: no graph task found for #{issue.identifier}")
          nil
      end
    else
      nil
    end
  end

  defp format_task_context(nil), do: nil

  defp format_task_context(%Graph.Task{} = task) do
    sections = [
      if(task.kind, do: "Task kind: #{task.kind}"),
      if(task.id, do: "Graph task: #{task.id}"),
      format_criteria(task.acceptance_criteria),
      format_scope(task.scope),
      format_validation(task.validation),
      format_last_failure(task.last_failure)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n")
    end
  end

  defp format_criteria(nil), do: nil
  defp format_criteria([]), do: nil

  defp format_criteria(criteria) do
    lines = Enum.map(criteria, &"- #{&1}")
    "Acceptance criteria:\n#{Enum.join(lines, "\n")}"
  end

  defp format_scope(nil), do: nil

  defp format_scope(%Graph.Scope{include: include, exclude: exclude}) do
    parts = []

    parts =
      if include != [] do
        parts ++ ["In scope: #{Enum.join(include, ", ")}"]
      else
        parts
      end

    parts =
      if exclude != [] do
        parts ++ ["Out of scope: #{Enum.join(exclude, ", ")}"]
      else
        parts
      end

    case parts do
      [] -> nil
      _ -> Enum.join(parts, "\n")
    end
  end

  defp format_last_failure(nil), do: nil

  defp format_last_failure(lf) do
    parts =
      [
        if(lf.linear_issue_identifier, do: "Issue: #{lf.linear_issue_identifier}"),
        if(lf.category, do: "Category: #{lf.category}"),
        if(lf.stage, do: "Stage: #{lf.stage}"),
        if(lf.reason, do: "Reason: #{lf.reason}")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [] do
      nil
    else
      "Previous attempt failed:\n#{Enum.join(parts, "\n")}"
    end
  end

  defp format_validation(nil), do: nil

  defp format_validation(%Graph.Validation{commands: commands}) when commands != [] do
    lines = Enum.map(commands, &"- #{&1}")
    "Validation commands:\n#{Enum.join(lines, "\n")}"
  end

  defp format_validation(_), do: nil

  defp default_branch(issue_identifier) do
    "issue-" <> String.downcase(issue_identifier)
  end

  defp default_pr_title(%{identifier: issue_identifier}), do: "Implement #{issue_identifier}"
  defp default_pr_body(%{identifier: issue_identifier}), do: "Implements #{issue_identifier}"

  defp worker_start(worker_adapter, attrs) when is_map(worker_adapter),
    do: worker_adapter.start_session.(attrs)

  defp worker_start(worker_adapter, attrs), do: apply(worker_adapter, :start_session, [attrs])

  defp worker_run_prompt(worker_adapter, session, prompt, opts) when is_map(worker_adapter) do
    case :erlang.fun_info(worker_adapter.run_prompt, :arity) do
      {:arity, 3} -> worker_adapter.run_prompt.(session, prompt, opts)
      {:arity, 2} -> worker_adapter.run_prompt.(session, prompt)
    end
  end

  defp worker_run_prompt(worker_adapter, session, prompt, opts) do
    if function_exported?(worker_adapter, :run_prompt, 3) do
      apply(worker_adapter, :run_prompt, [session, prompt, opts])
    else
      apply(worker_adapter, :run_prompt, [session, prompt])
    end
  end

  defp worker_stop(worker_adapter, session) when is_map(worker_adapter),
    do: worker_adapter.stop_session.(session)

  defp worker_stop(worker_adapter, session), do: apply(worker_adapter, :stop_session, [session])

  defp worker_supports_run_once?(worker_adapter) when is_map(worker_adapter) do
    Map.has_key?(worker_adapter, :run_once)
  end

  defp worker_supports_run_once?(worker_adapter) do
    function_exported?(worker_adapter, :run_once, 3)
  end

  defp worker_run_once(worker_adapter, attrs, prompt, opts) when is_map(worker_adapter) do
    case :erlang.fun_info(worker_adapter.run_once, :arity) do
      {:arity, 3} -> worker_adapter.run_once.(attrs, prompt, opts)
      {:arity, 2} -> worker_adapter.run_once.(attrs, prompt)
    end
  end

  defp worker_run_once(worker_adapter, attrs, prompt, opts) do
    apply(worker_adapter, :run_once, [attrs, prompt, opts])
  end

  defp current_branch(workspace) do
    case System.cmd("git", ["branch", "--show-current"], cd: workspace, stderr_to_stdout: true) do
      {branch, 0} ->
        {:ok, String.trim(branch)}

      {output, exit_status} ->
        {:error, {:command_failed, "git", exit_status, String.trim(output)}}
    end
  end
end
