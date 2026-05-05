defmodule BeamDesign.Agents.PromptComposer do
  @moduledoc """
  Build a system prompt from a skill body + design system body, for any
  BEAM-side agent that talks to a model with a system message slot
  (currently DeepInfra; future direct-OpenAI / direct-Anthropic adapters
  reuse this composer).

  Mirrors `apps/daemon/src/prompts/system.ts#composeSystemPrompt` in
  intent — design-system tokens are authoritative, the active skill
  drives the workflow — but with a much smaller surface. The JS
  composer also stacks discovery + philosophy + base-prompt scaffolding;
  we deliberately keep BEAM's first cut to the two pieces of content the
  user authored (skill + design system) plus a terse glue header.
  Revisit after Phase C if outputs underperform vs the JS path.

  Pure string-in / string-out by design — accepting `%Skill{}` /
  `%DesignSystem{}` structs would make this module depend on the Skills
  and DesignSystems boundaries, which the Agents boundary is not
  permitted to reach into. Callers (in Runs) extract the strings.
  """

  @type input :: %{
          optional(:skill_name) => String.t() | nil,
          optional(:skill_body) => String.t() | nil,
          optional(:design_system_title) => String.t() | nil,
          optional(:design_system_body) => String.t() | nil
        }

  @doc """
  Compose a system prompt string from the supplied skill / design
  system bodies. Any field may be nil; with both bodies missing this
  returns nil so callers can omit the system message entirely.
  """
  @spec build(input()) :: String.t() | nil
  def build(input) when is_map(input) do
    sections =
      []
      |> maybe_append(
        body_section(
          "Active design system",
          Map.get(input, :design_system_title),
          Map.get(input, :design_system_body)
        )
      )
      |> maybe_append(
        body_section(
          "Active skill",
          Map.get(input, :skill_name),
          Map.get(input, :skill_body)
        )
      )

    case sections do
      [] -> nil
      _ -> [glue() | sections] |> Enum.join("\n\n")
    end
  end

  defp glue do
    """
    You are an artifact-writing design agent. Treat the active design
    system below as authoritative for color, typography, spacing, and
    component tokens. Follow the active skill's workflow exactly. When
    file-writing tools are available, produce real files in the project
    directory — do not describe what the user should do in another tool.
    """
    |> String.trim()
  end

  defp body_section(_label, _name, nil), do: nil
  defp body_section(_label, _name, ""), do: nil

  defp body_section(label, name, body) when is_binary(body) do
    header =
      case name do
        n when is_binary(n) and n != "" -> "## #{label} — #{n}"
        _ -> "## #{label}"
      end

    header <> "\n\n" <> String.trim(body)
  end

  defp maybe_append(list, nil), do: list
  defp maybe_append(list, ""), do: list
  defp maybe_append(list, item), do: list ++ [item]
end
