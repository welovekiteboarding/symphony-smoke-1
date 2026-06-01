defmodule Symphony1.Planning.TaskAnalyzer do
  @moduledoc """
  Deterministic pre-materialization analysis for graph task size.

  This module does not call an AI model. It scores graph tasks using explicit
  graph facts so oversized work is caught before a Linear issue is created.
  """

  alias Symphony1.Planning.Graph

  @oversized_threshold 18
  @risk_terms ~w(ai worker performance security persistence end-to-end e2e optimization concurrency)

  defmodule Finding do
    @moduledoc false

    defstruct [
      :task_id,
      :severity,
      :score,
      :reasons,
      :recommended_action
    ]
  end

  defmodule Result do
    @moduledoc false

    defstruct findings: [], oversized_tasks: [], passed?: true
  end

  @spec analyze(Graph.t(), keyword()) :: Result.t()
  def analyze(%Graph{} = graph, opts \\ []) do
    include_done? = Keyword.get(opts, :include_done, false)

    findings =
      graph.tasks
      |> Enum.reject(fn task -> task.status == "done" and not include_done? end)
      |> Enum.map(&analyze_task/1)
      |> Enum.reject(&is_nil/1)

    oversized_tasks = Enum.map(findings, & &1.task_id)

    %Result{
      findings: findings,
      oversized_tasks: oversized_tasks,
      passed?: findings == []
    }
  end

  @spec analyze_task(Graph.Task.t()) :: Finding.t() | nil
  def analyze_task(%Graph.Task{} = task) do
    facts = score_facts(task)
    score = total_score(facts)
    reasons = reasons(facts)

    if score >= @oversized_threshold do
      %Finding{
        task_id: task.id,
        severity: :warning,
        score: score,
        reasons: reasons,
        recommended_action: "break_down_before_materialization"
      }
    end
  end

  defp score_facts(task) do
    acceptance_count = length(task.acceptance_criteria || [])
    scope_count = length(scope_include(task))
    description_words = word_count(task.description || "")
    risk_hits = risk_hits(task)

    %{
      acceptance_count: acceptance_count,
      scope_count: scope_count,
      description_words: description_words,
      risk_hits: risk_hits
    }
  end

  defp total_score(facts) do
    facts.acceptance_count * 3 +
      max(facts.scope_count - 3, 0) * 2 +
      div(facts.description_words, 50) +
      max(length(facts.risk_hits) - 1, 0) * 3
  end

  defp reasons(facts) do
    []
    |> maybe_add(facts.acceptance_count > 5, "too many acceptance criteria")
    |> maybe_add(facts.scope_count > 4, "too many in-scope paths")
    |> maybe_add(
      length(facts.risk_hits) > 1,
      "multiple high-risk concepts: #{Enum.join(facts.risk_hits, ", ")}"
    )
    |> maybe_add(facts.description_words > 120, "description is broad")
    |> Enum.reverse()
  end

  defp maybe_add(reasons, true, reason), do: [reason | reasons]
  defp maybe_add(reasons, false, _reason), do: reasons

  defp risk_hits(task) do
    text =
      [
        task.title,
        task.description,
        Enum.join(task.acceptance_criteria || [], " "),
        Enum.join(scope_include(task), " ")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.filter(@risk_terms, &String.contains?(text, &1))
  end

  defp scope_include(%Graph.Task{scope: %Graph.Scope{include: include}}), do: include || []
  defp scope_include(_task), do: []

  defp word_count(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> length()
  end
end
