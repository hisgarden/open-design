%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      strict: true,
      checks: [
        # Default Credo checks. Tighten as the codebase grows.
        {Credo.Check.Readability.ModuleDoc, false},
        {Credo.Check.Design.TagTODO, exit_status: 0}
      ]
    }
  ]
}
