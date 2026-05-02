defmodule BeamDesign.Agents.ClaudeCode do
  @moduledoc """
  Adapter for the local `claude` CLI (Claude Code).

  Spawns `claude` in non-interactive `--print` mode with `--output-format
  stream-json --verbose --bare` and parses the line-buffered JSONL into
  normalized run events. The `--bare` flag skips hooks, MCP, plugin sync,
  and CLAUDE.md auto-discovery — appropriate for daemon-driven runs that
  shouldn't inherit the maintainer's interactive shell config.

  Volatility absorbed here: if Claude Code's stream-json shape changes,
  only this module needs to update — the run server consumes the
  normalized events unchanged.
  """

  @default_bin_candidates [
    "/Users/jwen/.local/bin/claude",
    "/opt/homebrew/bin/claude",
    "claude"
  ]

  @doc """
  Open a Port wrapping the Claude CLI for the given prompt.

  Options:
    * `:model` — model alias or full name (default: nil, lets the CLI pick)
    * `:bin` — explicit path to the claude binary
    * `:cwd` — working directory for the CLI (default: System.tmp_dir!())
    * `:extra_args` — additional argv to append (advanced)

  Returns `{:ok, port}` or `{:error, reason}`.
  """
  @spec start(String.t(), keyword()) :: {:ok, port()} | {:error, term()}
  def start(prompt, opts \\ []) when is_binary(prompt) do
    bin = Keyword.get(opts, :bin) || resolve_bin()
    model = Keyword.get(opts, :model)
    cwd = Keyword.get(opts, :cwd) || System.tmp_dir!()
    extra = Keyword.get(opts, :extra_args, [])

    case bin do
      nil ->
        {:error, :claude_bin_not_found}

      path ->
        args =
          [
            "-p",
            prompt,
            "--bare",
            "--output-format",
            "stream-json",
            "--verbose"
          ] ++ model_args(model) ++ extra

        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :exit_status,
              {:line, 65_536},
              :hide,
              args: args,
              cd: cwd
            ]
          )

        {:ok, port}
    end
  end

  @doc """
  Parse one line of Claude's stream-json output into a normalized event tuple.

  Returns one of:
    * `{:status, %{phase: ..., model: ..., session_id: ...}}`
    * `{:text, String.t()}` — assistant text chunk
    * `{:meta, map()}` — anything we don't have a typed shape for yet
    * `{:result, %{success: bool, error?: String.t() | nil, duration_ms: integer(), cost_usd: float()}}`
    * `:skip` — non-JSON line or noise
  """
  @spec parse_line(String.t()) ::
          {:status, map()}
          | {:text, String.t()}
          | {:meta, map()}
          | {:result, map()}
          | :skip
  def parse_line(line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        :skip

      not String.starts_with?(trimmed, "{") ->
        :skip

      true ->
        case Jason.decode(trimmed) do
          {:ok, json} -> classify(json)
          {:error, _} -> :skip
        end
    end
  end

  defp classify(%{"type" => "system", "subtype" => subtype} = j) do
    {:status,
     %{
       phase: subtype,
       model: j["model"],
       session_id: j["session_id"],
       cwd: j["cwd"]
     }}
  end

  defp classify(%{"type" => "assistant", "message" => %{"content" => content}}) do
    text =
      content
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => t} when is_binary(t) -> [t]
        _ -> []
      end)
      |> Enum.join("")

    if text == "" do
      {:meta, %{kind: "assistant_non_text"}}
    else
      {:text, text}
    end
  end

  defp classify(%{"type" => "result"} = j) do
    {:result,
     %{
       success: j["is_error"] != true,
       error: if(j["is_error"] == true, do: j["result"], else: nil),
       duration_ms: j["duration_ms"],
       cost_usd: j["total_cost_usd"]
     }}
  end

  defp classify(j), do: {:meta, %{kind: "unrecognized", raw: j}}

  defp model_args(nil), do: []
  defp model_args(model) when is_binary(model), do: ["--model", model]

  defp resolve_bin do
    Enum.find(@default_bin_candidates, fn path ->
      cond do
        path == "claude" -> System.find_executable("claude") != nil
        true -> File.exists?(path) and File.stat!(path).mode |> Bitwise.band(0o100) > 0
      end
    end)
    |> case do
      "claude" -> System.find_executable("claude")
      other -> other
    end
  end
end
