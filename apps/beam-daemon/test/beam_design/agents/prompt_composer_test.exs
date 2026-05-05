defmodule BeamDesign.Agents.PromptComposerTest do
  use ExUnit.Case, async: true

  alias BeamDesign.Agents.PromptComposer

  test "returns nil when no skill or design system is provided" do
    assert PromptComposer.build(%{}) == nil
    assert PromptComposer.build(%{skill_body: nil, design_system_body: nil}) == nil
    assert PromptComposer.build(%{skill_body: "", design_system_body: ""}) == nil
  end

  test "includes the design system body when present" do
    out =
      PromptComposer.build(%{
        design_system_title: "Agentic",
        design_system_body: "Primary: #FF5701\nSecondary: #F6F6F1"
      })

    assert is_binary(out)
    assert out =~ "## Active design system — Agentic"
    assert out =~ "Primary: #FF5701"
  end

  test "includes the skill body when present" do
    out =
      PromptComposer.build(%{
        skill_name: "html-ppt",
        skill_body: "Open assets/template.html and copy its :root tokens."
      })

    assert is_binary(out)
    assert out =~ "## Active skill — html-ppt"
    assert out =~ "Open assets/template.html"
  end

  test "stacks design system before skill, with terse glue header" do
    out =
      PromptComposer.build(%{
        skill_name: "html-ppt",
        skill_body: "SKILL_BODY_MARKER",
        design_system_title: "Agentic",
        design_system_body: "DESIGN_BODY_MARKER"
      })

    assert is_binary(out)
    assert out =~ "artifact-writing design agent"
    design_idx = :binary.match(out, "DESIGN_BODY_MARKER") |> elem(0)
    skill_idx = :binary.match(out, "SKILL_BODY_MARKER") |> elem(0)
    assert design_idx < skill_idx
  end

  test "omits a section header when its body is missing" do
    out =
      PromptComposer.build(%{
        skill_name: "html-ppt",
        skill_body: "BODY",
        design_system_title: "Agentic",
        design_system_body: nil
      })

    assert is_binary(out)
    refute out =~ "Active design system"
    assert out =~ "Active skill"
  end

  test "uses a generic label when the name is blank" do
    out =
      PromptComposer.build(%{
        skill_body: "BODY"
      })

    assert is_binary(out)
    assert out =~ "## Active skill\n"
    refute out =~ "## Active skill —"
  end

  test "trims whitespace around bodies but keeps internal newlines" do
    out =
      PromptComposer.build(%{
        skill_body: "\n\nline 1\nline 2\n\n"
      })

    assert is_binary(out)
    assert out =~ "line 1\nline 2"
    refute out =~ "line 2\n\n\n"
  end
end
