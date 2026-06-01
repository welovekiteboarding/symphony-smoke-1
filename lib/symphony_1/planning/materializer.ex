defmodule Symphony1.Planning.Materializer do
  @moduledoc """
  Materializes the ready batch from a planning graph into Linear issues.

  For each ready task that is not already materialized, creates a Linear
  issue and writes the mapping (linear_issue_id, linear_issue_identifier)
  back into the graph. Already-materialized tasks are skipped.

  The updated graph (with mappings) is returned so the caller can persist it.
  """

  require Logger

  alias Symphony1.Planning.{Batcher, Graph, Validator}
  alias Symphony1.Project.SetupIntent

  @default_project_type "symphony"

  @type materialized_entry :: %{
          task_id: String.t(),
          linear_issue_id: String.t(),
          linear_issue_identifier: String.t()
        }

  @type result :: %{
          graph: Graph.t(),
          materialized: [materialized_entry()],
          skipped: [String.t()],
          invalid_tasks: [map()]
        }

  @type issue_creation_failure_reason :: {:issue_creation_failed, term()}

  @type materialize_error_reason ::
          issue_creation_failure_reason()
          | {:recovery_snapshot_pending, blocking_recovery_snapshot()}
          | {:recovery_snapshot_scan_failed, term()}

  @type error_result :: %{
          graph: Graph.t(),
          materialized: [materialized_entry()],
          skipped: [String.t()],
          invalid_tasks: [map()],
          failed_task_id: String.t(),
          reason: materialize_error_reason()
        }

  @type persistence_failure :: %{
          durability: Graph.durability_guarantee(),
          graph_path: String.t(),
          graph_write_error: term(),
          recovery_snapshot_path: String.t() | nil,
          recovery_snapshot_error: term() | nil
        }

  @type blocking_recovery_snapshot :: %{
          path: String.t(),
          blocking_task_ids: [String.t()],
          materialized_issue_identifiers: [String.t()]
        }

  @type persistence_failure_context :: %{
          failed_task_id: String.t(),
          reason: materialize_error_reason()
        }

  @type persistence_error_reason ::
          {:graph_persistence_failed, persistence_failure(), persistence_failure_context() | nil}

  @type persistence_error_result :: %{
          graph: Graph.t(),
          materialized: [materialized_entry()],
          skipped: [String.t()],
          invalid_tasks: [map()],
          failed_task_id: String.t() | nil,
          reason: persistence_error_reason(),
          persistence_failure: persistence_failure()
        }

  @spec materialize(Graph.t(), map(), keyword()) :: {:ok, result()} | {:error, error_result()}
  def materialize(%Graph{} = graph, linear_config, opts \\ []) do
    issue_creator = Keyword.get(opts, :issue_creator, &default_issue_creator/2)
    project_type = resolve_project_type(opts)

    batch = Batcher.compute(graph)
    {to_create, skipped} = partition_ready(batch.ready_tasks)
    skipped_ids = Enum.map(skipped, & &1.id)
    {valid_to_create, invalid_tasks} = partition_admissible(to_create, project_type)

    case maybe_block_for_recovery_snapshot(graph, valid_to_create, opts) do
      :ok ->
        with {:ok, graph, materialized} <-
               create_issues(valid_to_create, graph, linear_config, issue_creator) do
          {:ok,
           %{
             graph: graph,
             materialized: materialized,
             skipped: skipped_ids,
             invalid_tasks: invalid_tasks
           }}
        else
          {:error, graph, materialized, failed_task_id, reason} ->
            {:error,
             %{
               graph: graph,
               materialized: materialized,
               skipped: skipped_ids,
               invalid_tasks: invalid_tasks,
               failed_task_id: failed_task_id,
               reason: reason
             }}
        end

      {:error, failed_task_id, reason} ->
        {:error,
         %{
           graph: graph,
           materialized: [],
           skipped: skipped_ids,
           invalid_tasks: invalid_tasks,
           failed_task_id: failed_task_id,
           reason: reason
         }}
    end
  end

  @doc """
  Materializes ready tasks and persists the resulting graph through the
  explicit graph durability boundary before returning.

  Error results are intentionally split into two precise shapes:

  * `error_result/0` for materialization failures before graph persistence finishes
  * `persistence_error_result/0` when Linear side effects succeeded but graph persistence failed

  Persistence failures always include top-level `failed_task_id` and `reason` fields so
  callers can pattern match on `{:graph_persistence_failed, persistence_failure, context}`
  instead of probing for optional map keys.
  """
  @spec materialize_and_persist(Graph.t(), map(), String.t(), keyword()) ::
          {:ok, result()} | {:error, error_result() | persistence_error_result()}
  def materialize_and_persist(%Graph{} = graph, linear_config, graph_path, opts \\ []) do
    opts = Keyword.put(opts, :graph_path, graph_path)

    graph_writer = Keyword.get(opts, :graph_writer, &Graph.persist/2)

    recovery_snapshot_writer =
      Keyword.get(opts, :recovery_snapshot_writer, &default_recovery_snapshot_writer/1)

    case materialize(graph, linear_config, opts) do
      {:ok, result} ->
        case persist_materialization_result(
               result,
               graph_path,
               graph_writer,
               recovery_snapshot_writer,
               nil
             ) do
          :ok ->
            {:ok, result}

          {:error, persistence_failure} ->
            {:error, persistence_error_result(result, persistence_failure, nil)}
        end

      {:error, error} ->
        if persist_failed_materialization?(error) do
          failure_context = %{failed_task_id: error.failed_task_id, reason: error.reason}

          case persist_materialization_result(
                 error,
                 graph_path,
                 graph_writer,
                 recovery_snapshot_writer,
                 failure_context
               ) do
            :ok ->
              {:error, error}

            {:error, persistence_failure} ->
              {:error, persistence_error_result(error, persistence_failure, failure_context)}
          end
        else
          {:error, error}
        end
    end
  end

  defp partition_ready(ready_tasks) do
    Enum.split_with(ready_tasks, fn task ->
      not task.materialization.materialized
    end)
  end

  defp create_issues(tasks, graph, config, issue_creator) do
    Enum.reduce_while(tasks, {:ok, graph, []}, fn task, {:ok, g, results} ->
      case create_one(task, config, issue_creator) do
        {:ok, issue} ->
          Logger.info(
            "symphony.materializer: created #{issue.identifier} for graph task #{task.id}"
          )

          {:ok, updated_graph} =
            Graph.update_task(g, task.id, %{
              status: "in_progress",
              materialization: %{
                materialized: true,
                linear_issue_id: issue.id,
                linear_issue_identifier: issue.identifier
              }
            })

          result = %{
            task_id: task.id,
            linear_issue_id: issue.id,
            linear_issue_identifier: issue.identifier
          }

          {:cont, {:ok, updated_graph, results ++ [result]}}

        {:error, reason} ->
          Logger.warning(
            "symphony.materializer: failed to create issue for #{task.id}: #{inspect(reason)}"
          )

          {:halt, {:error, g, results, task.id, {:issue_creation_failed, reason}}}
      end
    end)
  end

  defp partition_admissible(tasks, project_type) do
    Enum.reduce(tasks, {[], []}, fn task, {valid, invalid} ->
      case Validator.validate_task_admission(task, project_type: project_type) do
        :ok ->
          {valid ++ [task], invalid}

        {:error, reason} ->
          Logger.warning(
            "symphony.materializer: admission failed for #{task.id}: #{inspect(reason)}"
          )

          {valid, invalid ++ [%{task_id: task.id, reason: reason}]}
      end
    end)
  end

  defp create_one(task, config, issue_creator) do
    attrs = %{
      "title" => task.title,
      "description" => build_description(task),
      "state" => "Todo"
    }

    issue_creator.(config, attrs)
  end

  defp build_description(task) do
    sections = [
      "Graph task: #{task.id}",
      if(task.kind, do: "Kind: #{task.kind}"),
      task.description,
      format_criteria(task.acceptance_criteria),
      format_scope(task.scope),
      format_validation(task.validation),
      format_last_failure(task.last_failure)
    ]

    sections
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
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
    parts = if include != [], do: parts ++ ["In scope: #{Enum.join(include, ", ")}"], else: parts

    parts =
      if exclude != [], do: parts ++ ["Out of scope: #{Enum.join(exclude, ", ")}"], else: parts

    if parts == [], do: nil, else: Enum.join(parts, "\n")
  end

  defp format_validation(nil), do: nil

  defp format_validation(%Graph.Validation{setup_commands: setup_commands, commands: commands})
       when setup_commands != [] or commands != [] do
    [
      format_command_section("Setup commands", setup_commands),
      format_command_section("Validation commands", commands),
      """
      Symphony finalization owns the full setup and validation run after the worker returns.
      During the worker turn, implement first; use these commands as focused post-change checks only if time remains.
      """
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
    |> String.trim()
  end

  defp format_validation(_), do: nil

  defp format_command_section(_label, []), do: nil

  defp format_command_section(label, commands) do
    lines = Enum.map(commands, &"- #{&1}")
    "#{label}:\n#{Enum.join(lines, "\n")}"
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

  defp default_issue_creator(config, attrs) do
    Symphony1.Core.Linear.create_issue(config, attrs)
  end

  defp persist_materialization_result(
         payload,
         graph_path,
         graph_writer,
         recovery_snapshot_writer,
         failure_context
       ) do
    case graph_writer.(payload.graph, graph_path) do
      :ok ->
        :ok

      {:error, reason} ->
        snapshot_payload =
          recovery_snapshot_payload(
            graph_path,
            reason,
            payload.materialized,
            payload.skipped,
            failure_context
          )

        case recovery_snapshot_writer.(snapshot_payload) do
          {:ok, recovery_snapshot_path} ->
            {:error,
             %{
               durability: Graph.durability_guarantee(),
               graph_path: graph_path,
               graph_write_error: reason,
               recovery_snapshot_path: recovery_snapshot_path,
               recovery_snapshot_error: nil
             }}

          {:error, recovery_snapshot_error} ->
            {:error,
             %{
               durability: Graph.durability_guarantee(),
               graph_path: graph_path,
               graph_write_error: reason,
               recovery_snapshot_path: nil,
               recovery_snapshot_error: recovery_snapshot_error
             }}
        end
    end
  end

  defp persist_failed_materialization?(%{materialized: materialized}) do
    materialized != []
  end

  defp persistence_error_result(payload, persistence_failure, failure_context) do
    %{
      graph: payload.graph,
      materialized: payload.materialized,
      skipped: payload.skipped,
      invalid_tasks: payload.invalid_tasks,
      failed_task_id: failure_context && failure_context.failed_task_id,
      reason: {:graph_persistence_failed, persistence_failure, failure_context},
      persistence_failure: persistence_failure
    }
  end

  @doc false
  def default_recovery_snapshot_writer(payload) do
    recovery_dir = recovery_snapshot_write_dir(payload)

    with :ok <- File.mkdir_p(recovery_dir),
         {:ok, encoded_payload} <- Jason.encode(payload, pretty: true) do
      write_recovery_snapshot(recovery_dir, encoded_payload)
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def materialization_error_message(error, opts \\ [])

  def materialization_error_message(
        %{reason: {:graph_persistence_failed, persistence_failure, failure_context}} = error,
        opts
      ) do
    graph_persistence_error_message(error, persistence_failure, failure_context, opts)
  end

  def materialization_error_message(%{persistence_failure: persistence_failure} = error, opts) do
    graph_persistence_error_message(error, persistence_failure, nil, opts)
  end

  def materialization_error_message(%{reason: {:recovery_snapshot_pending, snapshot}}, opts) do
    prefix = Keyword.get(opts, :prefix, "")

    task_details =
      snapshot.blocking_task_ids
      |> Enum.map(&"task #{&1}")
      |> Enum.join(", ")

    issue_details = Enum.join(snapshot.materialized_issue_identifiers, ", ")

    issue_suffix =
      if issue_details == "" do
        ""
      else
        " Existing Linear issues: #{issue_details}."
      end

    prefix <>
      "materialization blocked: recovery snapshot #{snapshot.path} still owns graph task(s): " <>
      "#{task_details}.#{issue_suffix} #{recovery_guidance(snapshot.path)}"
  end

  def materialization_error_message(%{reason: {:recovery_snapshot_scan_failed, reason}}, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    prefix <> "failed to scan recovery snapshots before materialization: #{inspect(reason)}"
  end

  def materialization_error_message(
        %{failed_task_id: failed_task_id, reason: {:issue_creation_failed, reason}},
        opts
      ) do
    prefix = Keyword.get(opts, :prefix, "")
    prefix <> "materialization failed on task #{failed_task_id}: #{inspect(reason)}"
  end

  def materialization_error_message(%{failed_task_id: failed_task_id, reason: reason}, opts) do
    prefix = Keyword.get(opts, :prefix, "")
    prefix <> "materialization failed on task #{failed_task_id}: #{inspect(reason)}"
  end

  defp graph_persistence_error_message(error, persistence_failure, failure_context, opts) do
    prefix = Keyword.get(opts, :prefix, "")

    details =
      error.materialized
      |> Enum.map(& &1.linear_issue_identifier)
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    materialized_suffix =
      if details == "" do
        ""
      else
        " Materialized issues: #{details}"
      end

    prior_failure_suffix =
      case failure_context do
        %{failed_task_id: failed_task_id, reason: reason} ->
          " Prior materialization failure: task #{failed_task_id} -> #{inspect(reason)}."

        nil ->
          ""
      end

    recovery_suffix =
      case persistence_failure.recovery_snapshot_path do
        nil ->
          case persistence_failure.recovery_snapshot_error do
            nil ->
              ""

            recovery_error ->
              ". Recovery snapshot write also failed: #{inspect(recovery_error)}"
          end

        recovery_path ->
          ". A recovery snapshot written to #{recovery_path}. #{recovery_guidance(recovery_path)}"
      end

    prefix <>
      "materialization graph write failed: #{inspect(persistence_failure.graph_write_error)}" <>
      recovery_suffix <> materialized_suffix <> prior_failure_suffix
  end

  defp recovery_guidance(snapshot_path) do
    "Run mix symphony.plan_materialize_recover --snapshot #{snapshot_path} before materializing again."
  end

  @doc false
  def recovery_snapshot_payload(graph_path, reason, materialized, skipped, failure_context) do
    %{
      graph_path: canonical_graph_path(graph_path),
      write_error: inspect(reason),
      materialized: materialized,
      skipped: skipped,
      failure_context: serialize_failure_context(failure_context)
    }
  end

  defp serialize_failure_context(nil), do: nil

  defp serialize_failure_context(failure_context) do
    %{
      failed_task_id: Map.get(failure_context, :failed_task_id),
      reason:
        case Map.get(failure_context, :reason) do
          nil -> nil
          reason -> inspect(reason)
        end
    }
  end

  @doc false
  def load_recovery_snapshot(path) do
    with {:ok, contents} <- read_recovery_snapshot(path),
         {:ok, snapshot} <- decode_recovery_snapshot(contents, path),
         :ok <- validate_recovery_snapshot(snapshot, path) do
      {:ok, snapshot}
    end
  end

  @doc false
  def find_blocking_recovery_snapshot(%Graph{} = graph, graph_path, opts \\ []) do
    recovery_dir = recovery_snapshot_dir(graph_path, opts)
    normalized_graph_path = canonical_graph_path(graph_path)

    recovery_snapshot_paths(recovery_dir)
    |> Enum.reduce_while({:ok, nil}, fn snapshot_path, {:ok, nil} ->
      case load_recovery_snapshot(snapshot_path) do
        {:ok, snapshot} ->
          if snapshot_matches_graph?(snapshot, normalized_graph_path) do
            case blocking_recovery_snapshot(snapshot, graph) do
              nil -> {:cont, {:ok, nil}}
              blocking -> {:halt, {:ok, blocking}}
            end
          else
            {:cont, {:ok, nil}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp maybe_block_for_recovery_snapshot(_graph, [], _opts), do: :ok

  defp maybe_block_for_recovery_snapshot(graph, tasks_to_create, opts) do
    case Keyword.get(opts, :graph_path) do
      nil ->
        :ok

      graph_path ->
        case find_blocking_recovery_snapshot(graph, graph_path, opts) do
          {:ok, nil} ->
            :ok

          {:ok, snapshot} ->
            failed_task_id =
              Enum.find_value(tasks_to_create, List.first(snapshot.blocking_task_ids), fn task ->
                if task.id in snapshot.blocking_task_ids, do: task.id
              end)

            {:error, failed_task_id, {:recovery_snapshot_pending, snapshot}}

          {:error, reason} ->
            {:error, List.first(tasks_to_create).id, {:recovery_snapshot_scan_failed, reason}}
        end
    end
  end

  @doc false
  def default_recovery_snapshot_dir(graph_path) do
    fingerprint =
      graph_path
      |> canonical_graph_path()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join(System.tmp_dir!(), Path.join("symphony-plan-materialize-recovery", fingerprint))
  end

  defp recovery_snapshot_dir(graph_path, opts) do
    Keyword.get_lazy(opts, :recovery_dir, fn ->
      Application.get_env(
        :symphony_1,
        :plan_materializer_recovery_dir,
        default_recovery_snapshot_dir(graph_path)
      )
    end)
  end

  defp recovery_snapshot_paths(recovery_dir) do
    recovery_dir
    |> Path.join("symphony-plan-materialize-recovery-*.json")
    |> Path.wildcard()
    |> Enum.sort(:desc)
  end

  defp recovery_snapshot_write_dir(payload) do
    Application.get_env(
      :symphony_1,
      :plan_materializer_recovery_dir,
      default_recovery_snapshot_dir(payload_graph_path(payload))
    )
  end

  defp payload_graph_path(payload) do
    Map.get(payload, :graph_path) || Map.get(payload, "graph_path")
  end

  defp write_recovery_snapshot(recovery_dir, encoded_payload) do
    unique_id = System.unique_integer([:positive, :monotonic])

    recovery_filename = "symphony-plan-materialize-recovery-#{unique_id}.json"
    recovery_path = Path.join(recovery_dir, recovery_filename)

    temp_path =
      Path.join(recovery_dir, ".symphony-plan-materialize-recovery-writing-#{unique_id}.tmp")

    case File.write(temp_path, encoded_payload) do
      :ok ->
        case File.rename(temp_path, recovery_path) do
          :ok ->
            {:ok, recovery_path}

          {:error, reason} ->
            File.rm(temp_path)
            {:error, reason}
        end

      {:error, reason} ->
        File.rm(temp_path)
        {:error, reason}
    end
  end

  defp blocking_recovery_snapshot(snapshot, graph) do
    blocking_entries =
      snapshot["materialized"]
      |> Enum.filter(fn entry ->
        case Enum.find(graph.tasks, &(&1.id == entry["task_id"])) do
          nil -> false
          task -> not recovery_snapshot_issue_recorded?(entry, task)
        end
      end)

    if blocking_entries == [] do
      nil
    else
      %{
        path: Map.fetch!(snapshot, "__path__"),
        blocking_task_ids: Enum.map(blocking_entries, & &1["task_id"]),
        materialized_issue_identifiers:
          blocking_entries
          |> Enum.map(& &1["linear_issue_identifier"])
          |> Enum.reject(&is_nil/1)
      }
    end
  end

  defp recovery_snapshot_issue_recorded?(entry, task) do
    snapshot_issue_matches_materialization?(entry, task.materialization) or
      snapshot_issue_matches_last_failure?(entry, task.last_failure)
  end

  defp snapshot_issue_matches_materialization?(_entry, nil), do: false

  defp snapshot_issue_matches_materialization?(entry, materialization) do
    snapshot_issue_matches_identity?(
      entry,
      materialization.linear_issue_id,
      materialization.linear_issue_identifier
    )
  end

  defp snapshot_issue_matches_last_failure?(_entry, nil), do: false

  defp snapshot_issue_matches_last_failure?(entry, last_failure) do
    snapshot_issue_matches_identity?(
      entry,
      last_failure.linear_issue_id,
      last_failure.linear_issue_identifier
    )
  end

  defp snapshot_issue_matches_identity?(entry, issue_id, issue_identifier) do
    matching_snapshot_value?(entry["linear_issue_id"], issue_id) or
      matching_snapshot_value?(entry["linear_issue_identifier"], issue_identifier)
  end

  defp matching_snapshot_value?(expected, actual)
       when is_binary(expected) and expected != "" and is_binary(actual) and actual != "" do
    expected == actual
  end

  defp matching_snapshot_value?(_expected, _actual), do: false

  defp snapshot_matches_graph?(snapshot, expanded_graph_path) do
    snapshot
    |> Map.fetch!("graph_path")
    |> canonical_graph_path()
    |> Kernel.==(expanded_graph_path)
  end

  @doc false
  def canonical_graph_path(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> resolve_path_components()
  end

  defp resolve_path_components(components, depth \\ 0)

  defp resolve_path_components(["/" | components], depth) do
    Enum.reduce(components, "/", fn component, current ->
      candidate = Path.join(current, component)
      resolve_symlink_target(candidate, current, depth)
    end)
  end

  defp resolve_path_components(components, _depth) do
    Path.join(components)
  end

  defp resolve_symlink_target(path, _parent_dir, depth) when depth >= 40 do
    path
  end

  defp resolve_symlink_target(path, parent_dir, depth) do
    case File.read_link(path) do
      {:ok, target} ->
        resolved_target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, parent_dir)
          end

        resolved_target
        |> Path.split()
        |> resolve_path_components(depth + 1)

      {:error, _reason} ->
        path
    end
  end

  defp read_recovery_snapshot(path) do
    case File.read(path) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:recovery_snapshot_read_failed, path, reason}}
    end
  end

  defp decode_recovery_snapshot(contents, path) do
    case Jason.decode(contents) do
      {:ok, snapshot} ->
        {:ok, Map.put(snapshot, "__path__", path)}

      {:error, reason} ->
        {:error, {:invalid_recovery_snapshot, path, {:decode_failed, reason}}}
    end
  end

  defp validate_recovery_snapshot(snapshot, path) when is_map(snapshot) do
    with :ok <- validate_snapshot_graph_path(snapshot, path),
         :ok <- validate_snapshot_materialized(snapshot, path) do
      :ok
    end
  end

  defp validate_recovery_snapshot(_snapshot, path) do
    {:error, {:invalid_recovery_snapshot, path, :snapshot_must_be_an_object}}
  end

  defp validate_snapshot_graph_path(snapshot, path) do
    if is_binary(snapshot["graph_path"]) and snapshot["graph_path"] != "" do
      :ok
    else
      {:error, {:invalid_recovery_snapshot, path, :missing_graph_path}}
    end
  end

  defp validate_snapshot_materialized(snapshot, path) do
    case Map.get(snapshot, "materialized") do
      materialized when is_list(materialized) ->
        Enum.reduce_while(materialized, :ok, fn entry, :ok ->
          case validate_snapshot_materialized_entry(entry) do
            :ok ->
              {:cont, :ok}

            {:error, reason} ->
              {:halt, {:error, {:invalid_recovery_snapshot, path, reason}}}
          end
        end)

      _other ->
        {:error, {:invalid_recovery_snapshot, path, :materialized_must_be_a_list}}
    end
  end

  defp validate_snapshot_materialized_entry(entry) when is_map(entry) do
    with :ok <- validate_snapshot_string(entry, "task_id"),
         :ok <- validate_snapshot_string(entry, "linear_issue_id"),
         :ok <- validate_snapshot_string(entry, "linear_issue_identifier") do
      :ok
    end
  end

  defp validate_snapshot_materialized_entry(_entry) do
    {:error, :materialized_entry_must_be_an_object}
  end

  defp validate_snapshot_string(entry, key) do
    value = Map.get(entry, key)

    if is_binary(value) and value != "" do
      :ok
    else
      {:error, {:missing_snapshot_key, key}}
    end
  end

  defp resolve_project_type(opts) do
    Keyword.get(opts, :project_type) ||
      infer_project_type_from_graph_path(Keyword.get(opts, :graph_path)) ||
      infer_project_type_from_dir(Keyword.get(opts, :cwd, File.cwd!())) ||
      @default_project_type
  end

  defp infer_project_type_from_graph_path(nil), do: nil

  defp infer_project_type_from_graph_path(path) do
    path
    |> Path.expand()
    |> Path.dirname()
    |> find_setup_intent_path()
    |> load_project_type()
  end

  defp infer_project_type_from_dir(dir) do
    dir
    |> Path.expand()
    |> find_setup_intent_path()
    |> load_project_type()
  end

  defp find_setup_intent_path(dir) do
    candidate = Path.join([dir, "config", "symphony_setup.json"])

    cond do
      File.exists?(candidate) ->
        candidate

      Path.dirname(dir) == dir ->
        nil

      true ->
        find_setup_intent_path(Path.dirname(dir))
    end
  end

  defp load_project_type(nil), do: nil

  defp load_project_type(path) do
    case SetupIntent.load(path) do
      {:ok, intent} -> get_in(intent, ["project", "type"])
      {:error, _reason} -> nil
    end
  end
end
