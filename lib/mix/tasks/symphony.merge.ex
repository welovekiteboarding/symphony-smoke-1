defmodule Mix.Tasks.Symphony.Merge do
  use Mix.Task

  alias Symphony1.MergeRuntime

  @shortdoc "Merge reviewed Symphony pull requests from the current repo"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [cwd: :string, once: :boolean]
      )

    if positional != [] or invalid != [] do
      Mix.raise("usage: mix symphony.merge [--once] [--cwd PATH]")
    end

    merge_runtime_runner =
      Application.get_env(:symphony_1, :merge_runtime_runner, &MergeRuntime.run/1)

    runtime_opts = [
      once: Keyword.get(opts, :once, false),
      cwd: Keyword.get(opts, :cwd, File.cwd!())
    ]

    case merge_runtime_runner.(runtime_opts) do
      {:ok, result} ->
        once? = Keyword.get(opts, :once, false)
        emit_merge_message(once?, result)
        maybe_wait_forever(once?)

      {:error, reason} ->
        Mix.raise("merge failed: #{inspect(reason)}")
    end
  end

  defp emit_merge_message(true, %{report: %{summary: summary}} = result) when is_binary(summary) do
    Mix.shell().info(summary)
    emit_report_warnings(result)
  end

  defp emit_merge_message(true, %{results: results} = result) do
    Enum.each(results, fn result ->
      issue_identifier = get_in(result, [:issue, :identifier]) || "unknown-issue"
      issue_state = get_in(result, [:issue, :state]) || "unknown-state"
      pull_request_url = get_in(result, [:pull_request, :url]) || "no-pr"

      Mix.shell().info("Merged #{issue_identifier} -> #{issue_state} (#{pull_request_url})")
    end)

    emit_report_warnings(result)
  end

  defp emit_merge_message(false, _result) do
    Mix.shell().info("Symphony merge runtime started")
  end

  defp maybe_wait_forever(true), do: :ok

  defp maybe_wait_forever(false) do
    waiter =
      Application.get_env(
        :symphony_1,
        :merge_runtime_waiter,
        fn ->
          receive do
          end
        end
      )

    waiter.()
  end

  defp emit_report_warnings(%{report: %{warnings: warnings}})
       when is_list(warnings) and warnings != [] do
    Enum.each(warnings, &emit_warning/1)
  end

  defp emit_report_warnings(%{base_refresh: {:warning, reason}}) do
    emit_warning(%{
      code: :base_refresh_failed,
      reason: reason,
      summary: "Local base refresh failed after merge: #{inspect(reason)}."
    })
  end

  defp emit_report_warnings(_result), do: :ok

  defp emit_warning(%{summary: summary}) when is_binary(summary) do
    Mix.shell().info("Warning: #{summary}")
  end
end
