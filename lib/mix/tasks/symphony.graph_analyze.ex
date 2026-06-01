defmodule Mix.Tasks.Symphony.GraphAnalyze do
  use Mix.Task

  alias Symphony1.Planning.{Graph, TaskAnalyzer, TaskBreakdown}

  @shortdoc "Analyze graph task size and optionally write deterministic breakdowns"
  @max_breakdown_rounds 4

  @impl true
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        strict: [
          graph: :string,
          cwd: :string,
          write_breakdown: :boolean
        ]
      )

    graph_path =
      case Keyword.get(opts, :graph) do
        nil -> Mix.raise("usage: mix symphony.graph_analyze --graph PATH --cwd REPO")
        path -> path
      end

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    write_breakdown? = Keyword.get(opts, :write_breakdown, false)

    with {:ok, graph} <- Graph.load(graph_path) do
      result = TaskAnalyzer.analyze(graph)

      if result.passed? do
        Mix.shell().info("Graph analysis: passed")
      else
        print_findings(result)

        if write_breakdown? do
          write_breakdown(graph, graph_path, result.oversized_tasks)
        else
          Mix.shell().info("No graph tasks should be materialized until this is resolved.")
          Mix.shell().info("To write a deterministic breakdown, run:")

          Mix.shell().info(
            "  mix symphony.graph_analyze --graph #{graph_path} --cwd #{cwd} --write-breakdown"
          )
        end
      end
    else
      {:error, reason} -> Mix.raise("failed to load graph: #{inspect(reason)}")
    end
  end

  defp print_findings(%TaskAnalyzer.Result{findings: findings}) do
    Mix.shell().info("Graph analysis: failed")
    Mix.shell().info("Oversized tasks:")

    Enum.each(findings, fn finding ->
      Mix.shell().info("  #{finding.task_id}: score #{finding.score}")

      Enum.each(finding.reasons, fn reason ->
        Mix.shell().info("    - #{reason}")
      end)
    end)
  end

  defp write_breakdown(graph, graph_path, task_ids) do
    case breakdown_until_pass(graph, task_ids, [], 1) do
      {:ok, updated_graph, proposals} ->
        :ok = Graph.write(updated_graph, graph_path)
        Mix.shell().info("Wrote breakdown for #{length(proposals)} oversized task(s):")
        Enum.each(proposals, &print_proposal/1)

      {:error, reason} ->
        Mix.raise("graph breakdown failed: #{inspect(reason)}")
    end
  end

  defp breakdown_until_pass(graph, [], proposals, _round), do: {:ok, graph, proposals}

  defp breakdown_until_pass(_graph, task_ids, _proposals, round)
       when round > @max_breakdown_rounds do
    {:error, {:breakdown_did_not_converge, task_ids}}
  end

  defp breakdown_until_pass(graph, task_ids, proposals, round) do
    with {:ok, updated_graph, new_proposals} <- break_down_tasks(graph, task_ids) do
      result = TaskAnalyzer.analyze(updated_graph)
      all_proposals = proposals ++ new_proposals

      if result.passed? do
        {:ok, updated_graph, all_proposals}
      else
        breakdown_until_pass(updated_graph, result.oversized_tasks, all_proposals, round + 1)
      end
    end
  end

  defp break_down_tasks(graph, task_ids) do
    case TaskBreakdown.break_down(graph, task_ids) do
      {:ok, updated_graph, %TaskBreakdown.Proposal{} = proposal} ->
        {:ok, updated_graph, [proposal]}

      {:ok, updated_graph, proposals} ->
        {:ok, updated_graph, proposals}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_proposal(%TaskBreakdown.Proposal{} = proposal) do
    Mix.shell().info("  #{proposal.task_id} -> #{Enum.join(proposal.child_ids, ", ")}")
  end
end
