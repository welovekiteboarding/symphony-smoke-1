defmodule Symphony1.Core.Worker do
  @type run_spec :: %{
          command: String.t(),
          args: [String.t()],
          cd: String.t(),
          env: %{optional(String.t()) => String.t()}
        }

  @type session :: %{
          port: port(),
          buffer: String.t(),
          next_id: pos_integer(),
          thread_id: String.t() | nil,
          turn_id: String.t() | nil
        }

  @initialize_timeout 10_000
  @turn_timeout 60_000

  @spec local_run_spec(map()) :: run_spec()
  def local_run_spec(%{workspace: workspace, workflow_path: workflow_path}) do
    %{
      command: "codex",
      args: ["app-server", "--listen", "stdio://"],
      cd: workspace,
      env: %{
        "SYMPHONY_WORKFLOW_PATH" => workflow_path
      }
    }
  end

  @spec start_run(map()) :: {:ok, port()} | {:error, term()}
  def start_run(attrs) do
    spec = local_run_spec(attrs)

    case System.find_executable(spec.command) do
      nil ->
        {:error, {:missing_executable, spec.command}}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            {:args, Enum.map(spec.args, &String.to_charlist/1)},
            {:cd, String.to_charlist(spec.cd)},
            {:env,
             Enum.map(spec.env, fn {key, value} ->
               {String.to_charlist(key), String.to_charlist(value)}
             end)}
          ])

        {:ok, port}
    end
  rescue
    error -> {:error, error}
  end

  @spec start_session(map()) :: {:ok, session()} | {:error, term()}
  def start_session(attrs) do
    with {:ok, port} <- start_run(attrs),
         {:ok, session} <-
           initialize(%{port: port, buffer: "", next_id: 1, thread_id: nil, turn_id: nil}, attrs),
         {:ok, session} <- start_thread(session, attrs) do
      {:ok, session}
    else
      {:error, _reason} = error ->
        error
    end
  end

  @spec run_prompt(session(), String.t(), keyword()) ::
          {:ok, %{output: String.t(), thread_id: String.t(), turn_id: String.t()}}
          | {:error, term()}
  def run_prompt(session, prompt, opts \\ []) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @turn_timeout)
    log_paths = prompt_log_paths(opts)

    request = %{
      "id" => session.next_id,
      "method" => "turn/start",
      "params" => %{
        "threadId" => session.thread_id,
        "input" => [
          %{"type" => "text", "text" => prompt}
        ]
      }
    }

    with :ok <- prepare_prompt_logs(log_paths, session, prompt, opts),
         :ok <- send_json(session.port, request),
         {:ok, session, _turn_response} <-
           await_response(Map.merge(session, log_paths), session.next_id, @initialize_timeout),
         {:ok, _session, result} <-
           await_turn_completion(
             Map.merge(%{session | next_id: session.next_id + 1}, log_paths),
             timeout_ms
           ),
         :ok <- write_prompt_output(log_paths, result.output),
         :ok <- finish_prompt_metadata(log_paths, %{status: "ok", turn_id: result.turn_id}) do
      {:ok, Map.put(result, :thread_id, session.thread_id)}
    else
      {:error, reason} = error ->
        _ = finish_prompt_metadata(log_paths, %{status: "error", error: inspect(reason)})
        error
    end
  end

  @spec run_once(map(), String.t(), keyword()) ::
          {:ok, %{output: String.t(), thread_id: String.t() | nil, turn_id: String.t() | nil}}
          | {:error, term()}
  def run_once(attrs, prompt, opts \\ []) do
    workspace = Map.fetch!(attrs, :workspace)
    workflow_path = Map.fetch!(attrs, :workflow_path)
    command_runner = Keyword.get(opts, :command_runner, &run_command/3)
    log_dir = Keyword.get(opts, :log_dir, default_log_dir(workspace))
    output_path = Keyword.get(opts, :output_path, Path.join(log_dir, "worker-last-message.txt"))
    prompt_path = Keyword.get(opts, :prompt_path, Path.join(log_dir, "worker-prompt.txt"))
    raw_log_path = Keyword.get(opts, :raw_log_path, Path.join(log_dir, "worker.jsonl"))
    meta_path = Keyword.get(opts, :meta_path, Path.join(log_dir, "worker-meta.json"))
    timeout_ms = Keyword.get(opts, :timeout_ms, @turn_timeout)
    cleanup_output? = Keyword.get(opts, :output_path) == nil
    cleanup_prompt? = Keyword.get(opts, :prompt_path) == nil
    codex_command = Keyword.get(opts, :codex_command, "codex")

    args = [
      "exec",
      "--json",
      "-C",
      workspace,
      "-m",
      Keyword.get(opts, :model, "gpt-5.4"),
      "-s",
      "workspace-write",
      "--output-last-message",
      output_path,
      "-"
    ]

    shell_command =
      "exec " <>
        shell_join([codex_command | args]) <>
        " < " <>
        shell_escape(prompt_path)

    cmd_opts = [
      cd: workspace,
      env: command_env(workflow_path),
      stderr_to_stdout: true,
      timeout: timeout_ms,
      raw_log_path: raw_log_path
    ]

    try do
      with :ok <- File.mkdir_p(log_dir),
           :ok <- File.write(prompt_path, prompt),
           :ok <- File.write(raw_log_path, ""),
           :ok <- write_worker_metadata(meta_path, workspace, workflow_path, shell_command) do
        case command_runner.("zsh", ["-lc", shell_command], cmd_opts) do
          {stdout, 0} ->
            with {:ok, output} <- read_exec_output(output_path, stdout),
                 {:ok, metadata} <- parse_exec_metadata(stdout) do
              {:ok,
               %{
                 output: output,
                 thread_id: Map.get(metadata, :thread_id),
                 turn_id: Map.get(metadata, :turn_id)
               }}
            end

          {stdout, status} ->
            {:error, {:command_failed, "codex exec", status, String.trim(stdout)}}
        end
      end
    after
      # Keep default workspace-local artifacts for post-failure diagnosis.
      if cleanup_output? and not String.starts_with?(output_path, log_dir),
        do: File.rm(output_path)

      if cleanup_prompt? and not String.starts_with?(prompt_path, log_dir),
        do: File.rm(prompt_path)
    end
  end

  @spec stop_session(session()) :: :ok | {:error, term()}
  def stop_session(session) do
    stop_run(session.port)
  end

  @spec stop_run(port()) :: :ok | {:error, term()}
  def stop_run(port) do
    Port.close(port)
    :ok
  rescue
    error -> {:error, error}
  end

  @doc false
  @spec decode_buffer(String.t()) :: {:ok, [map()], String.t()} | {:error, term()}
  def decode_buffer(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [_partial] ->
        {:ok, [], buffer}

      parts ->
        complete = Enum.drop(parts, -1)
        rest = List.last(parts)

        with {:ok, messages} <- decode_complete_lines(complete) do
          {:ok, messages, rest}
        end
    end
  end

  defp initialize(session, _attrs) do
    request = %{
      "id" => session.next_id,
      "method" => "initialize",
      "params" => %{
        "clientInfo" => %{
          "name" => "symphony-1",
          "version" => "0.1.0"
        }
      }
    }

    with :ok <- send_json(session.port, request),
         {:ok, session, _response} <-
           await_response(session, session.next_id, @initialize_timeout),
         :ok <- send_json(session.port, %{"method" => "initialized"}) do
      {:ok, %{session | next_id: session.next_id + 1}}
    end
  end

  defp start_thread(session, attrs) do
    request = %{
      "id" => session.next_id,
      "method" => "thread/start",
      "params" => %{
        "approvalPolicy" => "never",
        "cwd" => attrs.workspace,
        "model" => "gpt-5.4",
        "personality" => "pragmatic",
        "sandbox" => "danger-full-access"
      }
    }

    with :ok <- send_json(session.port, request),
         {:ok, session, %{"thread" => %{"id" => thread_id}}} <-
           await_response(session, session.next_id, @initialize_timeout) do
      {:ok, %{session | next_id: session.next_id + 1, thread_id: thread_id}}
    end
  end

  defp await_turn_completion(session, timeout_ms) do
    await_turn_completion(
      session,
      %{output: "", turn_id: nil},
      System.monotonic_time(:millisecond) + timeout_ms
    )
  end

  defp await_turn_completion(session, result, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      {:error, :turn_timeout}
    else
      case consume_buffered_turn_messages(session, result, deadline_ms) do
        {:continue, session, result} ->
          receive do
            {port, {:data, data}} when port == session.port ->
              case decode_session_messages(%{session | buffer: session.buffer <> data}) do
                {:ok, session, messages} ->
                  case consume_turn_messages(messages, result) do
                    {:completed, result} ->
                      {:ok, session, result}

                    {:continue, result} ->
                      await_turn_completion(session, result, deadline_ms)
                  end

                {:error, reason} ->
                  {:error, reason}
              end

            {port, {:exit_status, status}} when port == session.port ->
              {:error, {:worker_exit, status}}
          after
            remaining ->
              {:error, :turn_timeout}
          end

        completed_or_error ->
          completed_or_error
      end
    end
  end

  defp consume_buffered_turn_messages(%{buffer: ""} = session, result, _deadline_ms) do
    {:continue, session, result}
  end

  defp consume_buffered_turn_messages(session, result, deadline_ms) do
    case decode_session_messages(session) do
      {:ok, session, []} ->
        {:continue, session, result}

      {:ok, session, messages} ->
        case consume_turn_messages(messages, result) do
          {:completed, result} ->
            {:ok, session, result}

          {:continue, result} ->
            await_turn_completion(session, result, deadline_ms)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp consume_turn_messages(messages, result) do
    Enum.reduce_while(messages, {:continue, result}, fn
      %{
        "method" => "item/completed",
        "params" => %{"item" => %{"type" => "agentMessage", "text" => text} = item}
      },
      {:continue, result} ->
        updated =
          result
          |> Map.put(:output, text)
          |> Map.put(:turn_id, Map.get(item, "turnId", result.turn_id))

        {:cont, {:continue, updated}}

      %{"method" => "item/agentMessage/delta", "params" => %{"delta" => delta}},
      {:continue, result} ->
        {:cont, {:continue, %{result | output: result.output <> delta}}}

      %{"method" => "turn/started", "params" => %{"turn" => %{"id" => turn_id}}},
      {:continue, result} ->
        {:cont, {:continue, %{result | turn_id: turn_id}}}

      %{"method" => "turn/completed", "params" => %{"turn" => %{"status" => "completed"}}},
      {:continue, result} ->
        {:halt, {:completed, result}}

      _message, acc ->
        {:cont, acc}
    end)
  end

  defp await_response(session, id, timeout_ms) do
    receive do
      {port, {:data, data}} when port == session.port ->
        case decode_session_messages(%{session | buffer: session.buffer <> data}) do
          {:ok, session, messages} ->
            case take_response(messages, id) do
              nil ->
                await_response(session, id, timeout_ms)

              {%{"result" => result}, deferred_messages} ->
                {:ok, defer_messages(session, deferred_messages), result}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {port, {:exit_status, status}} when port == session.port ->
        {:error, {:worker_exit, status}}
    after
      timeout_ms ->
        {:error, {:timeout, id}}
    end
  end

  defp take_response(messages, id) do
    case Enum.split_while(messages, &(not response_message?(&1, id))) do
      {_before_response, []} ->
        nil

      {before_response, [response | after_response]} ->
        {response, before_response ++ after_response}
    end
  end

  defp response_message?(message, id) do
    Map.get(message, "id") == id and Map.has_key?(message, "result")
  end

  defp defer_messages(session, []), do: session

  defp defer_messages(session, messages) do
    deferred =
      messages
      |> Enum.map_join("", &(Jason.encode!(&1) <> "\n"))

    %{session | buffer: deferred <> session.buffer}
  end

  defp decode_session_messages(session) do
    with {:ok, messages, rest} <- decode_buffer(session.buffer) do
      _ = append_prompt_raw_log(Map.get(session, :raw_log_path), messages)
      {:ok, %{session | buffer: rest}, messages}
    end
  end

  defp decode_complete_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, messages} ->
      case Jason.decode(line) do
        {:ok, decoded} ->
          {:cont, {:ok, messages ++ [decoded]}}

        {:error, reason} ->
          {:halt, {:error, {:invalid_worker_message, line, reason}}}
      end
    end)
  end

  defp send_json(port, payload) do
    encoded = Jason.encode!(payload)
    Port.command(port, encoded <> "\n")
    :ok
  rescue
    error -> {:error, error}
  end

  defp default_log_dir(workspace) do
    Path.join(workspace, ".symphony")
  end

  defp write_worker_metadata(path, workspace, workflow_path, shell_command) do
    metadata = %{
      "command" => shell_command,
      "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "workspace" => workspace,
      "workflow_path" => workflow_path
    }

    File.write(path, Jason.encode!(metadata, pretty: true))
  end

  defp prompt_log_paths(opts) do
    case Keyword.get(opts, :log_dir) do
      nil ->
        %{}

      log_dir ->
        %{
          log_dir: log_dir,
          output_path:
            Keyword.get(opts, :output_path, Path.join(log_dir, "review-last-message.txt")),
          prompt_path: Keyword.get(opts, :prompt_path, Path.join(log_dir, "review-prompt.txt")),
          raw_log_path: Keyword.get(opts, :raw_log_path, Path.join(log_dir, "review.jsonl")),
          meta_path: Keyword.get(opts, :meta_path, Path.join(log_dir, "review-meta.json"))
        }
    end
  end

  defp prepare_prompt_logs(%{log_dir: log_dir} = paths, session, prompt, opts) do
    metadata =
      %{
        "started_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "thread_id" => session.thread_id,
        "timeout_ms" => Keyword.get(opts, :timeout_ms, @turn_timeout)
      }
      |> Map.merge(Keyword.get(opts, :metadata, %{}))

    with :ok <- File.mkdir_p(log_dir),
         :ok <- File.write(paths.prompt_path, prompt),
         :ok <- File.write(paths.raw_log_path, ""),
         :ok <- File.write(paths.meta_path, Jason.encode!(metadata, pretty: true)) do
      :ok
    end
  end

  defp prepare_prompt_logs(_paths, _session, _prompt, _opts), do: :ok

  defp write_prompt_output(%{output_path: output_path}, output) do
    File.write(output_path, String.trim(output))
  end

  defp write_prompt_output(_paths, _output), do: :ok

  defp finish_prompt_metadata(%{meta_path: meta_path}, updates) do
    metadata =
      case File.read(meta_path) do
        {:ok, contents} ->
          case Jason.decode(contents) do
            {:ok, decoded} -> decoded
            {:error, _reason} -> %{}
          end

        {:error, _reason} ->
          %{}
      end
      |> Map.merge(stringify_keys(updates))
      |> Map.put("finished_at", DateTime.utc_now() |> DateTime.to_iso8601())

    File.write(meta_path, Jason.encode!(metadata, pretty: true))
  end

  defp finish_prompt_metadata(_paths, _updates), do: :ok

  defp append_prompt_raw_log(nil, _messages), do: :ok
  defp append_prompt_raw_log(_path, []), do: :ok

  defp append_prompt_raw_log(path, messages) do
    lines = Enum.map_join(messages, "", &(Jason.encode!(&1) <> "\n"))
    File.write(path, lines, [:append])
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp run_command(command, args, opts) do
    {timeout_ms, opts} = Keyword.pop(opts, :timeout)
    {raw_log_path, cmd_opts} = Keyword.pop(opts, :raw_log_path)

    if timeout_ms do
      run_port_command(command, args, cmd_opts, raw_log_path, timeout_ms)
    else
      System.cmd(command, args, cmd_opts)
    end
  end

  defp run_port_command(command, args, opts, raw_log_path, timeout_ms) do
    port_opts =
      [
        :binary,
        :exit_status,
        {:args, Enum.map(args, &String.to_charlist/1)}
      ] ++ port_cd_opts(opts) ++ port_env_opts(opts) ++ port_stderr_opts(opts)

    port = Port.open({:spawn_executable, System.find_executable(command) || command}, port_opts)

    collect_port_command(port, raw_log_path, "", "", deadline_ms(timeout_ms))
  rescue
    error -> {Exception.message(error), 1}
  end

  defp collect_port_command(port, raw_log_path, stdout, buffer, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    if remaining == 0 do
      terminate_port(port)
      {stdout <> "\ncommand timed out after #{deadline_timeout(deadline)}ms", 124}
    else
      receive do
        {^port, {:data, data}} ->
          append_raw_exec_log(raw_log_path, data)
          stdout = stdout <> data
          {events, buffer} = decode_exec_stream(buffer <> data)

          if exec_turn_completed?(events) do
            terminate_port(port)
            {stdout, 0}
          else
            collect_port_command(port, raw_log_path, stdout, buffer, deadline)
          end

        {^port, {:exit_status, status}} ->
          {stdout, status}
      after
        remaining ->
          terminate_port(port)
          {stdout <> "\ncommand timed out after #{deadline_timeout(deadline)}ms", 124}
      end
    end
  end

  defp deadline_ms(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp deadline_timeout(deadline) do
    max(deadline - System.monotonic_time(:millisecond), 0)
  end

  defp decode_exec_stream(buffer) do
    case :binary.split(buffer, "\n", [:global]) do
      [_partial] ->
        {[], buffer}

      parts ->
        complete = Enum.drop(parts, -1)
        rest = List.last(parts)

        events =
          Enum.flat_map(complete, fn line ->
            case Jason.decode(line) do
              {:ok, decoded} -> [decoded]
              {:error, _reason} -> []
            end
          end)

        {events, rest}
    end
  end

  defp exec_turn_completed?(events) do
    Enum.any?(events, fn
      %{"type" => "turn.completed"} -> true
      %{"method" => "turn/completed"} -> true
      _event -> false
    end)
  end

  defp append_raw_exec_log(nil, _data), do: :ok

  defp append_raw_exec_log(path, data) do
    File.write(path, data, [:append])
  end

  defp terminate_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) ->
        _ = System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      _other ->
        :ok
    end

    Port.close(port)
    :ok
  rescue
    _error -> :ok
  end

  defp port_cd_opts(opts) do
    case Keyword.get(opts, :cd) do
      nil -> []
      cd -> [{:cd, String.to_charlist(cd)}]
    end
  end

  defp port_env_opts(opts) do
    env =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map(fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    if env == [], do: [], else: [{:env, env}]
  end

  defp port_stderr_opts(opts) do
    if Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout], else: []
  end

  defp command_env(workflow_path) do
    [{"SYMPHONY_WORKFLOW_PATH", workflow_path}]
    |> maybe_include_path()
  end

  defp maybe_include_path(env) do
    case System.get_env("PATH") do
      nil -> env
      path -> [{"PATH", path} | env]
    end
  end

  defp read_exec_output(output_path, stdout) do
    case File.read(output_path) do
      {:ok, output} ->
        {:ok, String.trim(output)}

      {:error, _reason} ->
        parse_last_agent_message(stdout)
    end
  end

  defp parse_exec_metadata(stdout) do
    metadata =
      stdout
      |> decoded_exec_events()
      |> Enum.reduce(%{}, fn
        %{"type" => "thread.started", "thread_id" => thread_id}, acc ->
          Map.put(acc, :thread_id, thread_id)

        %{"type" => "turn.started", "turn_id" => turn_id}, acc ->
          Map.put(acc, :turn_id, turn_id)

        _event, acc ->
          acc
      end)

    {:ok, metadata}
  end

  defp parse_last_agent_message(stdout) do
    output =
      stdout
      |> decoded_exec_events()
      |> Enum.reduce(nil, fn
        %{"type" => "item.completed", "item" => %{"type" => "agent_message", "text" => text}},
        _acc ->
          text

        _event, acc ->
          acc
      end)

    case output do
      nil -> {:error, :missing_agent_message}
      text -> {:ok, String.trim(text)}
    end
  end

  defp decoded_exec_events(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Jason.decode(line) do
        {:ok, decoded} -> [decoded]
        {:error, _reason} -> []
      end
    end)
  end

  defp shell_join(args) do
    args
    |> Enum.map(&shell_escape/1)
    |> Enum.join(" ")
  end

  defp shell_escape(value) do
    "'" <> String.replace(to_string(value), "'", "'\"'\"'") <> "'"
  end
end
