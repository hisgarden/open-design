defmodule BeamDesign.Workspace.SandboxTest do
  use ExUnit.Case, async: true

  alias BeamDesign.Workspace.Sandbox

  setup do
    root = Path.join(System.tmp_dir!(), "beam-sandbox-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "safe_resolve/2 — accepts" do
    test "a simple relative path", %{root: root} do
      assert {:ok, abs} = Sandbox.safe_resolve(root, "slide-1.html")
      assert abs == Path.join(root, "slide-1.html")
    end

    test "a nested relative path under a not-yet-created dir", %{root: root} do
      assert {:ok, abs} = Sandbox.safe_resolve(root, "deck/slides/slide-1.html")
      assert String.starts_with?(abs, root)
    end

    test "a path that starts with ./", %{root: root} do
      assert {:ok, abs} = Sandbox.safe_resolve(root, "./slide.html")
      assert abs == Path.join(root, "slide.html")
    end
  end

  describe "safe_resolve/2 — rejects" do
    test "absolute paths", %{root: root} do
      assert {:error, :invalid_argument} = Sandbox.safe_resolve(root, "/etc/passwd")
    end

    test "empty relative path", %{root: root} do
      assert {:error, :invalid_argument} = Sandbox.safe_resolve(root, "")
    end

    test "non-binary inputs", %{root: root} do
      assert {:error, :invalid_argument} = Sandbox.safe_resolve(root, 123)
      assert {:error, :invalid_argument} = Sandbox.safe_resolve(root, nil)
    end

    test "dotdot escape outside root", %{root: root} do
      assert {:error, :escape} = Sandbox.safe_resolve(root, "../leaked.txt")
      assert {:error, :escape} = Sandbox.safe_resolve(root, "../../etc/passwd")
    end

    test "missing project_dir", _ do
      ghost = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer()}")
      assert {:error, {:invalid_project_dir, _}} = Sandbox.safe_resolve(ghost, "x.html")
    end

    test "symlink that points outside root", %{root: root} do
      escape_target = System.tmp_dir!()
      link = Path.join(root, "linked")
      File.ln_s!(escape_target, link)

      assert {:error, :escape} = Sandbox.safe_resolve(root, "linked/x.txt")
    end
  end

  describe "write_atomic/2" do
    test "writes content and creates parent dirs", %{root: root} do
      target = Path.join([root, "deck", "slide-1.html"])
      assert :ok = Sandbox.write_atomic(target, "<html>1</html>")
      assert File.read!(target) == "<html>1</html>"
    end

    test "leaves no .tmp residue on success", %{root: root} do
      target = Path.join(root, "x.html")
      assert :ok = Sandbox.write_atomic(target, "x")
      stale = File.ls!(root) |> Enum.filter(&String.contains?(&1, ".tmp"))
      assert stale == []
    end

    test "two concurrent writes to the same path don't collide on tmp suffix", %{root: root} do
      target = Path.join(root, "race.html")

      tasks =
        for i <- 1..10 do
          Task.async(fn -> Sandbox.write_atomic(target, "writer-#{i}") end)
        end

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.all?(results, &(&1 == :ok))
      content = File.read!(target)
      assert String.starts_with?(content, "writer-")
    end
  end

  describe "list_entries/1" do
    test "lists files and directories with type and size", %{root: root} do
      File.write!(Path.join(root, "a.html"), "AB")
      File.mkdir_p!(Path.join(root, "subdir"))

      assert {:ok, entries} = Sandbox.list_entries(root)
      names = Enum.map(entries, & &1.name) |> Enum.sort()
      assert "a.html" in names
      assert "subdir" in names

      file = Enum.find(entries, &(&1.name == "a.html"))
      assert file.type == :file
      assert file.size == 2

      dir = Enum.find(entries, &(&1.name == "subdir"))
      assert dir.type == :dir
    end

    test "returns error on missing dir", _ do
      ghost = Path.join(System.tmp_dir!(), "no-such-#{System.unique_integer()}")
      assert {:error, _} = Sandbox.list_entries(ghost)
    end
  end
end
