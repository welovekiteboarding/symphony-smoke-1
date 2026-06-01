defmodule Symphony1.Project.DependencySafety do
  @moduledoc false

  require Logger

  @blocking_severities ~w(high critical)

  @type command_runner :: (String.t(), [String.t()], keyword() -> {String.t(), non_neg_integer()})

  @spec run(Path.t(), command_runner(), String.t()) ::
          {:ok, %{changed: boolean()}} | {:error, term()}
  def run(workspace, runner, issue_identifier) do
    cond do
      npm_project?(workspace) ->
        run_npm_safety(workspace, runner, issue_identifier)

      true ->
        {:ok, %{changed: false}}
    end
  end

  defp npm_project?(workspace) do
    File.exists?(Path.join(workspace, "package.json")) and
      File.exists?(Path.join(workspace, "package-lock.json"))
  end

  defp run_npm_safety(workspace, runner, issue_identifier) do
    with {:ok, vulnerabilities} <- npm_audit(workspace, runner, issue_identifier) do
      blocking = blocking_vulnerabilities(vulnerabilities)

      cond do
        blocking == [] ->
          {:ok, %{changed: false}}

        Enum.any?(blocking, &non_breaking_fix_available?/1) ->
          with :ok <- npm_audit_fix(workspace, runner, issue_identifier),
               {:ok, post_fix_vulnerabilities} <- npm_audit(workspace, runner, issue_identifier) do
            remaining = blocking_vulnerabilities(post_fix_vulnerabilities)

            if remaining == [] do
              {:ok, %{changed: true}}
            else
              dependency_safety_error("npm", remaining)
            end
          end

        true ->
          dependency_safety_error("npm", blocking)
      end
    end
  end

  defp npm_audit(workspace, runner, issue_identifier) do
    case run_command(
           runner,
           "npm audit --omit=dev --json",
           workspace,
           issue_identifier,
           accept_nonzero_json?: true
         ) do
      {:ok, output} ->
        parse_npm_audit(output)

      {:error, exit_status, output} ->
        {:error, {:dependency_audit_failed, "npm", exit_status, output}}
    end
  end

  defp npm_audit_fix(workspace, runner, issue_identifier) do
    case run_command(runner, "npm audit fix --omit=dev", workspace, issue_identifier) do
      {:ok, _output} ->
        :ok

      {:error, exit_status, output} ->
        {:error, {:dependency_audit_fix_failed, "npm", exit_status, output}}
    end
  end

  defp parse_npm_audit(""), do: {:ok, []}

  defp parse_npm_audit(output) do
    case Jason.decode(output) do
      {:ok, %{"vulnerabilities" => vulnerabilities}} when is_map(vulnerabilities) ->
        {:ok, Map.values(vulnerabilities)}

      {:ok, _report} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:dependency_audit_unparseable, "npm", Exception.message(reason)}}
    end
  end

  defp blocking_vulnerabilities(vulnerabilities) do
    Enum.filter(vulnerabilities, fn vulnerability ->
      vulnerability
      |> Map.get("severity", "")
      |> String.downcase()
      |> then(&(&1 in @blocking_severities))
    end)
  end

  defp non_breaking_fix_available?(%{"fixAvailable" => %{"isSemVerMajor" => false}}), do: true
  defp non_breaking_fix_available?(_vulnerability), do: false

  defp dependency_safety_error(manager, vulnerabilities) do
    {:error,
     {:dependency_safety_failed,
      %{
        manager: manager,
        vulnerabilities: Enum.map(vulnerabilities, &summarize_vulnerability/1)
      }}}
  end

  defp summarize_vulnerability(vulnerability) do
    fix = Map.get(vulnerability, "fixAvailable")

    %{
      name: Map.get(vulnerability, "name", "unknown"),
      severity: Map.get(vulnerability, "severity", "unknown"),
      fixed_version: fixed_version(fix),
      advisories: advisory_titles(Map.get(vulnerability, "via", []))
    }
  end

  defp fixed_version(%{"version" => version}), do: version
  defp fixed_version(_fix), do: nil

  defp advisory_titles(via) when is_list(via) do
    via
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Map.get(&1, "title"))
    |> Enum.reject(&is_nil/1)
  end

  defp advisory_titles(_via), do: []

  defp run_command(runner, shell_command, workspace, issue_identifier, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    command_string = "zsh -lc #{shell_command}"

    Logger.info(
      "symphony.dependency_safety: start issue=#{issue_identifier} cmd=#{inspect(command_string)} cwd=#{workspace}"
    )

    {output, exit_status} =
      runner.("zsh", ["-lc", shell_command], cd: workspace, stderr_to_stdout: true)

    elapsed_ms = System.monotonic_time(:millisecond) - started_at
    trimmed_output = String.trim(output)

    log_level = if exit_status == 0, do: :info, else: :warning

    Logger.log(
      log_level,
      "symphony.dependency_safety: finish issue=#{issue_identifier} cmd=#{inspect(command_string)} exit=#{exit_status} elapsed_ms=#{elapsed_ms} output=#{inspect(trimmed_output)}"
    )

    cond do
      exit_status == 0 ->
        {:ok, trimmed_output}

      Keyword.get(opts, :accept_nonzero_json?, false) and json_output?(trimmed_output) ->
        {:ok, trimmed_output}

      true ->
        {:error, exit_status, trimmed_output}
    end
  end

  defp json_output?(output), do: String.starts_with?(output, "{")
end
