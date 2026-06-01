defmodule Mix.Tasks.Symphony.Review do
  use Mix.Task

  alias Symphony1.ReviewRuntime

  @shortdoc "Review one Symphony pull request from Human Review"
  @usage "usage: mix symphony.review --once [--cwd PATH] [--graph PATH]"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [cwd: :string, graph: :string, once: :boolean]
      )

    if positional != [] or invalid != [] or Keyword.get(opts, :once) != true do
      Mix.raise(@usage)
    end

    cwd = Keyword.get(opts, :cwd, File.cwd!())

    runtime_runner =
      Application.get_env(:symphony_1, :review_runtime_runner, &ReviewRuntime.run/1)

    runtime_opts =
      [once: true, cwd: cwd]
      |> maybe_put_graph_path(Keyword.get(opts, :graph))

    case runtime_runner.(runtime_opts) do
      {:ok, %{results: []}} ->
        Mix.shell().info("No reviewable issues found")

      {:ok, %{results: [result | _]}} ->
        case result.outcome do
          "approved" ->
            Mix.shell().info("Reviewed #{result.issue_identifier} -> approved")

          "changes_requested" ->
            Mix.shell().info("Reviewed #{result.issue_identifier} -> changes_requested")
        end

      {:error, reason} ->
        Mix.raise("review failed: #{inspect(reason)}")
    end
  end

  defp maybe_put_graph_path(opts, nil), do: opts
  defp maybe_put_graph_path(opts, graph_path), do: Keyword.put(opts, :graph_path, graph_path)
end
