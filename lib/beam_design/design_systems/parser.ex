defmodule BeamDesign.DesignSystems.Parser do
  @moduledoc """
  Parse one `DESIGN.md` file into a normalized `%DesignSystem{}` record.

  open-design's DESIGN.md convention (no YAML frontmatter):

      # Design System Inspired by <Name>

      > Category: <Category>
      > <Description>

      ## 1. Visual Theme & Atmosphere
      …

  Anything we can't extract gracefully degrades to nil; the body is
  always preserved verbatim so clients can do their own deeper parsing.
  """

  defmodule DesignSystem do
    @moduledoc false
    defstruct [:id, :title, :category, :description, :body, :path]

    @type t :: %__MODULE__{
            id: String.t(),
            title: String.t() | nil,
            category: String.t() | nil,
            description: String.t() | nil,
            body: String.t(),
            path: Path.t()
          }
  end

  @spec parse_file(Path.t()) :: {:ok, DesignSystem.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, body} <- File.read(path),
         id when is_binary(id) <- Path.basename(Path.dirname(path)) do
      {:ok, parse(body, id, path)}
    end
  end

  @spec parse(String.t(), String.t(), Path.t()) :: DesignSystem.t()
  def parse(body, id, path) do
    %DesignSystem{
      id: id,
      title: extract_title(body),
      category: extract_quoted_field(body, "Category:"),
      description: extract_first_unprefixed_quote(body),
      body: body,
      path: path
    }
  end

  defp extract_title(body) do
    body
    |> String.split("\n", parts: 30)
    |> Enum.find_value(fn
      "# " <> title -> String.trim(title)
      _ -> nil
    end)
  end

  defp extract_quoted_field(body, prefix) do
    body
    |> String.split("\n", parts: 30)
    |> Enum.find_value(fn
      "> " <> rest ->
        case String.trim_leading(rest) do
          ^prefix <> value -> String.trim(value)
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  # The first `> ...` line that isn't a `Category:` style label is treated
  # as the human-readable description.
  defp extract_first_unprefixed_quote(body) do
    body
    |> String.split("\n", parts: 30)
    |> Enum.find_value(fn
      "> " <> rest ->
        trimmed = String.trim(rest)
        if String.contains?(trimmed, ":") and label?(trimmed), do: nil, else: trimmed

      _ ->
        nil
    end)
  end

  defp label?(line) do
    [head | _] = String.split(line, ":", parts: 2)
    String.length(head) <= 30 and head =~ ~r/^[A-Za-z][A-Za-z0-9 _-]*$/
  end
end
