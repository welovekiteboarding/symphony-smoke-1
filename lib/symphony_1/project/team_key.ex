defmodule Symphony1.Project.TeamKey do
  @moduledoc false

  @spec default_team_key(String.t()) :: String.t()
  def default_team_key(project_name) do
    key =
      project_name
      |> String.split(~r/[^a-zA-Z0-9]+/, trim: true)
      |> Enum.map(&team_key_segment/1)
      |> Enum.join()
      |> String.upcase()

    if key == "", do: "SYM", else: key
  end

  defp team_key_segment(segment) do
    if String.match?(segment, ~r/^\d+$/) do
      segment
    else
      String.first(segment)
    end
  end
end
