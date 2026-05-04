defmodule BeamDesign.Skills.Parser do
  @moduledoc """
  Parse one `SKILL.md` file into a normalized `%Skill{}` record.

  open-design's SKILL.md convention is YAML-frontmatter + markdown body:

      ---
      name: my-skill
      description: |
        Multi-line prose…
      triggers:
        - "x"
        - "y"
      ---

      # body markdown
      …

  Frontmatter is parsed via yaml_elixir; missing/malformed frontmatter
  degrades to a Skill with metadata = nil and body = the full file.
  """

  defmodule Skill do
    @moduledoc false
    defstruct [:id, :name, :description, :triggers, :metadata, :body, :path]

    @type t :: %__MODULE__{
            id: String.t(),
            name: String.t() | nil,
            description: String.t() | nil,
            triggers: [String.t()],
            metadata: map(),
            body: String.t(),
            path: Path.t()
          }
  end

  @spec parse_file(Path.t()) :: {:ok, Skill.t()} | {:error, term()}
  def parse_file(path) do
    with {:ok, content} <- File.read(path),
         id when is_binary(id) <- Path.basename(Path.dirname(path)) do
      {:ok, parse(content, id, path)}
    end
  end

  @spec parse(String.t(), String.t(), Path.t()) :: Skill.t()
  def parse(content, id, path) do
    {meta, body} = split_frontmatter(content)

    %Skill{
      id: id,
      name: meta["name"] || id,
      description: meta["description"],
      triggers: List.wrap(meta["triggers"] || []),
      metadata: meta,
      body: body,
      path: path
    }
  end

  defp split_frontmatter("---\n" <> rest) do
    case String.split(rest, ~r/\n---\n?/, parts: 2) do
      [yaml, body] ->
        case YamlElixir.read_from_string(yaml) do
          {:ok, %{} = map} -> {map, String.trim_leading(body, "\n")}
          _ -> {%{}, "---\n" <> rest}
        end

      _ ->
        {%{}, "---\n" <> rest}
    end
  end

  defp split_frontmatter(content), do: {%{}, content}
end
