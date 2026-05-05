defmodule BeamDesign.Agents.ToolsTest do
  use ExUnit.Case, async: true

  alias BeamDesign.Agents.Tools

  setup do
    root = Path.join(System.tmp_dir!(), "tools-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  describe "definitions/0" do
    test "returns three function-tool definitions" do
      defs = Tools.definitions()
      names = defs |> Enum.map(& &1.function.name) |> Enum.sort()
      assert names == ["list_files", "read_file", "write_file"]
      assert Enum.all?(defs, &(&1.type == "function"))
    end

    test "every tool declares required parameters" do
      for d <- Tools.definitions() do
        required = d.function.parameters.required
        assert is_list(required)
        assert length(required) >= 1
      end
    end
  end

  describe "execute/3 — write_file" do
    test "writes content and reports byte count", %{root: root} do
      result = Tools.execute("write_file", %{"path" => "x.html", "content" => "<p>hi</p>"}, root)
      assert result.ok == true
      assert result.bytes == byte_size("<p>hi</p>")
      assert File.read!(Path.join(root, "x.html")) == "<p>hi</p>"
    end

    test "creates nested parent dirs", %{root: root} do
      result =
        Tools.execute(
          "write_file",
          %{"path" => "deck/slides/s1.html", "content" => "x"},
          root
        )

      assert result.ok == true
      assert File.read!(Path.join([root, "deck", "slides", "s1.html"])) == "x"
    end

    test "rejects path that escapes the sandbox", %{root: root} do
      result =
        Tools.execute(
          "write_file",
          %{"path" => "../outside.txt", "content" => "leak"},
          root
        )

      assert %{error: msg} = result
      assert msg =~ "escape"
    end

    test "rejects missing path argument", %{root: root} do
      assert %{error: msg} = Tools.execute("write_file", %{"content" => "x"}, root)
      assert msg =~ "path"
    end

    test "rejects missing content argument", %{root: root} do
      assert %{error: msg} = Tools.execute("write_file", %{"path" => "x.html"}, root)
      assert msg =~ "content"
    end

    test "accepts explicitly empty content (truncate semantics)", %{root: root} do
      result =
        Tools.execute("write_file", %{"path" => "blank.html", "content" => ""}, root)

      assert result.ok == true
      assert File.read!(Path.join(root, "blank.html")) == ""
    end
  end

  describe "execute/3 — read_file" do
    test "reads existing file", %{root: root} do
      File.write!(Path.join(root, "a.txt"), "alpha")
      result = Tools.execute("read_file", %{"path" => "a.txt"}, root)
      assert result.ok == true
      assert result.content == "alpha"
    end

    test "returns structured error on missing file", %{root: root} do
      result = Tools.execute("read_file", %{"path" => "ghost.txt"}, root)
      assert %{error: _} = result
    end

    test "rejects escape", %{root: root} do
      result = Tools.execute("read_file", %{"path" => "../etc/passwd"}, root)
      assert %{error: msg} = result
      assert msg =~ "escape"
    end
  end

  describe "execute/3 — list_files" do
    test "lists root directory entries", %{root: root} do
      File.write!(Path.join(root, "a.html"), "")
      File.write!(Path.join(root, "b.html"), "")
      File.mkdir_p!(Path.join(root, "subdir"))

      result = Tools.execute("list_files", %{"dir" => "."}, root)
      assert result.ok == true
      assert result.dir == "."
      names = result.entries |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["a.html", "b.html", "subdir"]
    end

    test "defaults dir to '.' when missing", %{root: root} do
      result = Tools.execute("list_files", %{}, root)
      assert result.ok == true
    end

    test "rejects escape", %{root: root} do
      result = Tools.execute("list_files", %{"dir" => "../.."}, root)
      assert %{error: msg} = result
      assert msg =~ "escape"
    end
  end

  describe "execute/3 — unknown tool" do
    test "returns a structured error for an unrecognized name", %{root: root} do
      result = Tools.execute("delete_database", %{}, root)
      assert %{error: msg} = result
      assert msg =~ "unknown tool"
    end
  end
end
