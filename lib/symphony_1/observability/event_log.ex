defmodule Symphony1.Observability.EventLog do
  @moduledoc """
  Append-only JSONL storage helpers for Symphony observability events.

  This module owns append-only file writes and secret redaction. Higher-level
  recorder modules are responsible for deciding which events to write.
  """

  @sensitive_fragments ~w(api_key authorization bearer password secret token)
  @sensitive_value_patterns [
    {~r/(\bauthorization\b\s*:\s*bearer\s+)([^\s]+)/i, "\\1[REDACTED]"},
    {~r/(\b(?:api[_-]?key|token|password|secret)\b\s*[:=]\s*)([^\s]+)/i, "\\1[REDACTED]"}
  ]
  @secret_value_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/,
    ~r/\bgh[pousr]_[A-Za-z0-9_]{8,}\b/
  ]

  @spec append(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def append(cwd, event, details \\ %{}) when is_binary(cwd) and is_binary(event) do
    append_entry(path(cwd), %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      event: event,
      details: details
    })
  end

  @spec sanitize(term()) :: term()
  def sanitize(value), do: redact(value)

  @spec path(String.t()) :: String.t()
  def path(cwd), do: Path.join([cwd, "tmp", "symphony", "events.jsonl"])

  @spec append_entry(String.t(), map()) :: :ok | {:error, term()}
  def append_entry(path, entry) when is_binary(path) and is_map(entry) do
    entry = sanitize(entry)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, line} <- Jason.encode(entry),
         :ok <- File.write(path, line <> "\n", [:append]) do
      :ok
    end
  end

  defp redact(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> redact()

  defp redact(%{} = map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(to_string(key)) do
        {key, "[REDACTED]"}
      else
        {key, redact(value)}
      end
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value) when is_binary(value), do: redact_string(value)
  defp redact(value), do: value

  defp redact_string(value) do
    value =
      Enum.reduce(@sensitive_value_patterns, value, fn {pattern, replacement}, acc ->
        Regex.replace(pattern, acc, replacement)
      end)

    Enum.reduce(@secret_value_patterns, value, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  defp sensitive_key?(key) do
    normalized = String.downcase(key)
    Enum.any?(@sensitive_fragments, &String.contains?(normalized, &1))
  end
end
