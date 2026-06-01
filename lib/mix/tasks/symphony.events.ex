defmodule Mix.Tasks.Symphony.Events do
  use Mix.Task

  alias Symphony1.Observability.RunSummary

  @shortdoc "Summarize recent Symphony recorder events"
  @usage "usage: mix symphony.events [--cwd PATH] [--issue ISSUE-ID] [--last N]"

  @impl true
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [cwd: :string, issue: :string, last: :integer]
      )

    if positional != [] or invalid != [] do
      Mix.raise(@usage)
    end

    last = Keyword.get(opts, :last, RunSummary.default_last())

    if not is_integer(last) or last < 1 do
      Mix.raise(@usage)
    end

    cwd = Keyword.get(opts, :cwd, File.cwd!())
    issue_identifier = Keyword.get(opts, :issue)

    cwd
    |> RunSummary.events_report(issue: issue_identifier, last: last)
    |> RunSummary.render_events_report()
    |> Mix.shell().info()
  end
end
