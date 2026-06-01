defmodule Symphony1.ReviewRuntime do
  alias Symphony1.Core.{GitHub, Linear}
  alias Symphony1.Observability.Recorder
  alias Symphony1.MergeRuntime
  alias Symphony1.Planning.Graph
  alias Symphony1.Planning.ScopeCheck
  alias Symphony1.Review
  alias Symphony1.WorkspaceRoot

  @graph_path "planning/graph.json"

  @spec run(keyword()) :: {:ok, %{results: [map()]}} | {:error, term()}
  def run(opts \\ []) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    graph_path = resolve_graph_path(cwd, Keyword.get(opts, :graph_path, @graph_path))
    build_attrs = Keyword.get(opts, :build_attrs, &MergeRuntime.build_merge_attrs/1)
    issue_lister = Keyword.get(opts, :issue_lister, &Linear.list_team_issues/1)

    linear_poller =
      Keyword.get(opts, :linear_poller, fn config ->
        poll_human_review_issue(config, graph_path, issue_lister)
      end)

    github_resolver = Keyword.get(opts, :github_resolver, &resolve_pull_request/1)
    candidate_builder = Keyword.get(opts, :candidate_builder, &build_candidate/4)
    review_runner = Keyword.get(opts, :review_runner, &Review.review/1)
    transitioner = Keyword.get(opts, :transitioner, &transition_to_rework/3)

    with {:ok, review_attrs} <- build_attrs.(cwd) do
      case linear_poller.(review_attrs.linear_config) do
        :none ->
          {:ok, %{results: []}}

        {:ok, issue} ->
          case review_once(
                 issue,
                 cwd,
                 review_attrs,
                 graph_path,
                 github_resolver,
                 candidate_builder,
                 review_runner,
                 transitioner
               ) do
            {:ok, result} ->
              {:ok, %{results: [result]}}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp handle_review_result(
         %{"outcome" => "approved", "issue_identifier" => issue_identifier},
         _issue,
         _linear_config,
         _transitioner,
         _graph_path
       ) do
    {:ok, %{issue_identifier: issue_identifier, outcome: "approved"}}
  end

  defp handle_review_result(
         %{"outcome" => "changes_requested", "issue_identifier" => issue_identifier} = artifact,
         issue,
         linear_config,
         transitioner,
         graph_path
       ) do
    with {:ok, _updated_issue} <- transitioner.(issue, "Rework", linear_config),
         :ok <- record_review_failure(graph_path, issue_identifier, artifact) do
      {:ok, %{issue_identifier: issue_identifier, outcome: "changes_requested"}}
    else
      {:error, {:graph_load_error, _reason} = reason} ->
        {:error, {:review_graph_persistence_failed_after_transition, reason}}

      {:error, {:graph_write_error, _reason} = reason} ->
        {:error, {:review_graph_persistence_failed_after_transition, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_review_result(artifact, _issue, _linear_config, _transitioner, _graph_path) do
    {:error, {:invalid_review_artifact, artifact}}
  end

  defp record_review_failure(graph_path, issue_identifier, artifact) do
    failure_context = %{
      category: "review",
      stage: "automated_review",
      reason: review_failure_reason(artifact)
    }

    persist_review_failure_context(graph_path, issue_identifier, failure_context)
  end

  defp review_failure_reason(artifact) do
    findings =
      artifact
      |> Map.get("findings", [])
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    case findings do
      [] -> "changes_requested"
      _ -> "changes_requested: " <> Enum.join(findings, "\n")
    end
  end

  defp poll_human_review_issue(config, graph_path, issue_lister) do
    with {:ok, issues} <- issue_lister.(config) do
      human_review_issues = Enum.filter(issues, &(&1.state == "Human Review"))

      case graph_issue_identifiers(graph_path) do
        {:ok, identifiers} when identifiers != [] ->
          human_review_issues
          |> Enum.find(&MapSet.member?(identifiers, &1.identifier))
          |> case do
            nil -> :none
            issue -> {:ok, issue}
          end

        _other ->
          case human_review_issues do
            [] -> :none
            [issue | _rest] -> {:ok, issue}
          end
      end
    end
  end

  defp resolve_pull_request(attrs) do
    attrs
    |> Map.put(:state, "all")
    |> GitHub.find_pull_request_by_branch()
  end

  defp transition_to_rework(issue, new_state, linear_config) do
    Linear.transition_issue(issue, new_state, linear_config)
  end

  defp review_once(
         issue,
         cwd,
         review_attrs,
         graph_path,
         github_resolver,
         candidate_builder,
         review_runner,
         transitioner
       ) do
    branch = "issue-" <> String.downcase(issue.identifier)
    fallback_graph_task_id = graph_task_id_for_issue(issue.identifier, graph_path)
    fallback_workspace_path = workspace_path_for_issue(review_attrs, cwd, issue.identifier)

    case github_resolver.(%{
           branch: branch,
           repo: review_attrs.repo,
           state: "all",
           workspace: cwd,
           cwd: cwd
         }) do
      {:ok, pull_request} ->
        case build_review_candidate(
               candidate_builder,
               issue,
               pull_request,
               cwd,
               Map.put(review_attrs, :graph_path, graph_path)
             ) do
          {:ok, candidate} ->
            record_review_event(
              cwd,
              issue,
              candidate,
              pull_request,
              "review_started",
              %{},
              "info",
              fallback_graph_task_id,
              fallback_workspace_path
            )

            case review_runner.(candidate) do
              {:ok, artifact} ->
                case handle_review_result(
                       artifact,
                       issue,
                       review_attrs.linear_config,
                       transitioner,
                       graph_path
                     ) do
                  {:ok, result} ->
                    record_review_event(
                      cwd,
                      issue,
                      candidate,
                      pull_request,
                      "review_completed",
                      %{
                        outcome: result.outcome
                      },
                      "info",
                      fallback_graph_task_id,
                      fallback_workspace_path
                    )

                    {:ok, result}

                  {:error, {:review_graph_persistence_failed_after_transition, _reason} = reason} ->
                    record_review_event(
                      cwd,
                      issue,
                      candidate,
                      pull_request,
                      "review_failed",
                      %{
                        failure_reason: format_failure_reason(reason)
                      },
                      "warning",
                      fallback_graph_task_id,
                      fallback_workspace_path
                    )

                    {:error, reason}

                  {:error, reason} ->
                    record_review_event(
                      cwd,
                      issue,
                      candidate,
                      pull_request,
                      "review_failed",
                      %{
                        failure_reason: format_failure_reason(reason)
                      },
                      "warning",
                      fallback_graph_task_id,
                      fallback_workspace_path
                    )

                    recover_review_infrastructure_failure(
                      issue,
                      review_attrs.linear_config,
                      transitioner,
                      graph_path,
                      reason
                    )
                end

              {:error, reason} ->
                record_review_event(
                  cwd,
                  issue,
                  candidate,
                  pull_request,
                  "review_failed",
                  %{
                    failure_reason: format_failure_reason(reason)
                  },
                  "warning",
                  fallback_graph_task_id,
                  fallback_workspace_path
                )

                recover_review_infrastructure_failure(
                  issue,
                  review_attrs.linear_config,
                  transitioner,
                  graph_path,
                  reason
                )
            end

          {:error, reason} ->
            record_review_event(
              cwd,
              issue,
              nil,
              pull_request,
              "review_failed",
              %{
                failure_reason: format_failure_reason(reason)
              },
              "warning",
              fallback_graph_task_id,
              fallback_workspace_path
            )

            recover_review_infrastructure_failure(
              issue,
              review_attrs.linear_config,
              transitioner,
              graph_path,
              reason
            )
        end

      :none ->
        record_review_event(
          cwd,
          issue,
          nil,
          nil,
          "review_failed",
          %{
            branch: branch,
            failure_reason: "pull_request_not_found"
          },
          "warning",
          fallback_graph_task_id,
          fallback_workspace_path
        )

        recover_review_infrastructure_failure(
          issue,
          review_attrs.linear_config,
          transitioner,
          graph_path,
          :pull_request_not_found
        )

      {:error, reason} ->
        record_review_event(
          cwd,
          issue,
          nil,
          nil,
          "review_failed",
          %{
            branch: branch,
            failure_reason: format_failure_reason(reason)
          },
          "warning",
          fallback_graph_task_id,
          fallback_workspace_path
        )

        recover_review_infrastructure_failure(
          issue,
          review_attrs.linear_config,
          transitioner,
          graph_path,
          reason
        )
    end
  end

  defp recover_review_infrastructure_failure(
         issue,
         linear_config,
         transitioner,
         graph_path,
         reason
       ) do
    case record_review_infrastructure_failure(graph_path, issue.identifier, reason) do
      :ok ->
        transition_review_infrastructure_failure(issue, linear_config, transitioner)

      {:error, record_reason} ->
        {:error, {:review_infrastructure_failure, record_reason}}
    end
  end

  defp record_review_infrastructure_failure(graph_path, issue_identifier, reason) do
    failure_context = %{
      category: "review_infrastructure",
      stage: "automated_review",
      reason: format_failure_reason(reason)
    }

    persist_review_failure_context(graph_path, issue_identifier, failure_context)
  end

  defp transition_review_infrastructure_failure(issue, linear_config, transitioner) do
    case transitioner.(issue, "Rework", linear_config) do
      {:ok, _updated_issue} ->
        {:ok, %{issue_identifier: issue.identifier, outcome: "changes_requested"}}

      {:error, transition_reason} ->
        {:error, {:review_infrastructure_failure, transition_reason}}
    end
  end

  defp build_review_candidate(candidate_builder, issue, pull_request, cwd, review_attrs) do
    case :erlang.fun_info(candidate_builder, :arity) do
      {:arity, 4} -> candidate_builder.(issue, pull_request, cwd, review_attrs)
      {:arity, 3} -> candidate_builder.(issue, pull_request, cwd)
    end
  end

  defp build_candidate(issue, pull_request, cwd, review_attrs) do
    graph = load_graph(cwd, Map.get(review_attrs, :graph_path))

    task_context =
      case graph do
        {:ok, graph} ->
          case Graph.find_task_by_issue_identifier(graph, issue.identifier) do
            {:ok, task} -> task
            :none -> nil
          end

        {:error, _reason} ->
          nil
      end

    workspace_root = Map.get(review_attrs, :workspace_root, WorkspaceRoot.resolve(cwd, nil, nil))
    workspace = Path.join(workspace_root, issue.identifier)
    base_branch = Map.get(pull_request, :base_branch, "main")

    with {:ok, commit_sha} <- git_output(workspace, ["rev-parse", "HEAD"]),
         {:ok, changed_files_output} <-
           git_output(workspace, ["diff", "--name-only", "#{base_branch}...HEAD"]),
         {:ok, diff} <- git_output(workspace, ["diff", "--no-color", "#{base_branch}...HEAD"]) do
      changed_files = changed_files(changed_files_output)

      scope_check =
        if task_context, do: ScopeCheck.evaluate(task_context, changed_files), else: nil

      {:ok,
       %{
         repo_root: cwd,
         issue: issue,
         pull_request: pull_request,
         workspace: workspace,
         workflow_path: Path.join(cwd, "priv/workflows/WORKFLOW.md"),
         graph_task_id: if(task_context, do: task_context.id),
         task_context: task_context,
         commit_sha: commit_sha,
         changed_files: changed_files,
         scope_check: scope_check,
         diff: diff,
         validation_summary: validation_summary(task_context),
         supporting_docs: supporting_docs(cwd)
       }}
    end
  end

  defp load_graph(cwd, nil), do: Graph.load(Path.join(cwd, @graph_path))

  defp load_graph(_cwd, graph_path) do
    Graph.load(graph_path)
  end

  defp graph_issue_identifiers(graph_path) do
    with {:ok, graph} <- Graph.load(graph_path) do
      identifiers =
        graph.tasks
        |> Enum.map(&(&1.materialization || %Graph.Materialization{}))
        |> Enum.map(& &1.linear_issue_identifier)
        |> Enum.reject(&(&1 in [nil, ""]))
        |> MapSet.new()

      {:ok, identifiers}
    end
  end

  defp resolve_graph_path(cwd, graph_path) do
    if Path.type(graph_path) == :absolute do
      graph_path
    else
      Path.join(cwd, graph_path)
    end
  end

  defp supporting_docs(cwd) do
    [
      Path.join(cwd, "docs/project-orientation-and-source-of-truth.md"),
      Path.join(cwd, "docs/status.md")
    ]
  end

  defp validation_summary(nil), do: "Validation passed before PR open."

  defp validation_summary(task_context) do
    commands = validation_commands(task_context)

    case commands do
      [] ->
        "Validation passed before PR open."

      list ->
        "Validation passed before PR open with commands:\n" <>
          Enum.map_join(list, "\n", &"- #{&1}")
    end
  end

  defp validation_commands(task_context) when is_map(task_context) do
    validation = Map.get(task_context, :validation) || Map.get(task_context, "validation")

    case validation do
      nil ->
        []

      validation_map when is_map(validation_map) ->
        Map.get(validation_map, :commands) || Map.get(validation_map, "commands") || []
    end
  end

  defp persist_review_failure_context(graph_path, issue_identifier, failure_context) do
    with {:ok, graph} <- load_review_graph(graph_path),
         {:ok, updated_graph} <-
           record_review_graph_failure(graph, issue_identifier, failure_context),
         :ok <- write_review_graph(updated_graph, graph_path) do
      :ok
    end
  end

  defp load_review_graph(graph_path) do
    case Graph.load(graph_path) do
      {:ok, graph} -> {:ok, graph}
      {:error, :file_not_found} -> :ok
      {:error, reason} -> {:error, {:graph_load_error, reason}}
    end
  end

  defp record_review_graph_failure(graph, issue_identifier, failure_context) do
    case Graph.record_task_failure(graph, issue_identifier, failure_context) do
      {:ok, updated_graph} -> {:ok, updated_graph}
      :none -> :ok
    end
  end

  defp write_review_graph(:ok, _graph_path), do: :ok

  defp write_review_graph(updated_graph, graph_path) do
    case Graph.write(updated_graph, graph_path) do
      :ok -> :ok
      {:error, reason} -> {:error, {:graph_write_error, reason}}
    end
  end

  defp changed_files(""), do: []
  defp changed_files(output), do: String.split(output, "\n", trim: true)

  defp git_output(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, status} -> {:error, {:command_failed, "git", status, String.trim(output)}}
    end
  end

  defp record_review_event(
         cwd,
         issue,
         candidate,
         pull_request,
         event,
         details,
         severity,
         fallback_graph_task_id,
         fallback_workspace_path
       ) do
    Recorder.record(cwd, event,
      issue_identifier: issue.identifier,
      graph_task_id: candidate_graph_task_id(candidate, fallback_graph_task_id),
      phase: "review",
      severity: severity,
      details:
        %{
          workspace_path: workspace_path(candidate, fallback_workspace_path),
          branch: branch(candidate, pull_request),
          base_branch: base_branch(pull_request),
          pull_request_url: pull_request_url(pull_request)
        }
        |> Map.merge(details)
    )
  end

  defp workspace_path(nil, fallback), do: fallback
  defp workspace_path(candidate, fallback), do: Map.get(candidate, :workspace) || fallback

  defp workspace_path_for_issue(review_attrs, cwd, issue_identifier) do
    workspace_root = Map.get(review_attrs, :workspace_root, WorkspaceRoot.resolve(cwd, nil, nil))
    Path.join(workspace_root, issue_identifier)
  end

  defp branch(candidate, pull_request) do
    if candidate && Map.get(candidate, :pull_request) do
      Map.get(candidate.pull_request, :branch)
    else
      if pull_request, do: Map.get(pull_request, :branch)
    end
  end

  defp base_branch(nil), do: nil
  defp base_branch(pull_request), do: Map.get(pull_request, :base_branch)

  defp pull_request_url(nil), do: nil
  defp pull_request_url(pull_request), do: Map.get(pull_request, :url)

  defp candidate_graph_task_id(nil, fallback_graph_task_id), do: fallback_graph_task_id

  defp candidate_graph_task_id(candidate, fallback_graph_task_id) do
    Map.get(candidate, :graph_task_id) || fallback_graph_task_id
  end

  defp graph_task_id_for_issue(issue_identifier, graph_path) do
    with {:ok, graph} <- Graph.load(graph_path),
         {:ok, task} <- Graph.find_task_by_issue_identifier(graph, issue_identifier) do
      task.id
    else
      _error -> nil
    end
  end

  defp format_failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_failure_reason(reason) when is_binary(reason), do: reason
  defp format_failure_reason(reason), do: inspect(reason)
end
