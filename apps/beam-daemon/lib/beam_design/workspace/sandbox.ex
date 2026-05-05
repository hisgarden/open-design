defmodule BeamDesign.Workspace.Sandbox do
  @moduledoc """
  Confine agent file I/O to a single project directory.

  Every tool invocation hands us the run's `project_dir` (an absolute
  path the channel already validated against the OD_DATA_DIR allowlist)
  plus a model-supplied relative path. We resolve both, follow any
  symlinks, and refuse if the realpath leaves the project root.

  Path resolution rules:
    * The relative path must be a string, non-empty, and not absolute.
    * `..` segments are allowed but the resolved realpath still has to
      stay under the project root — climbing out of the sandbox via
      `../../etc/passwd` returns `{:error, :escape}`.
    * Symlinks inside the project that point outside are also caught
      because we compare realpaths, not literal joined paths.

  Writes go through a write-then-rename atomic step so a project-files
  watcher (in the JS daemon) sees a single `add` event per file rather
  than a partial-content `add` followed by `change`. The temp suffix
  uses `:crypto.strong_rand_bytes/1` so two concurrent writes to the
  same path never collide on temp file names.
  """

  @typedoc "Absolute, normalized path to the run's project directory."
  @type project_dir :: String.t()

  @doc """
  Resolve a model-supplied relative path against the project root.

  Returns `{:ok, abs_path}` when the resolved realpath is under
  `project_dir`. Returns `{:error, reason}` otherwise:

    * `:invalid_argument` — `rel_path` is empty, non-binary, or absolute
    * `:escape` — the resolved path leaves the project root
    * `{:invalid_project_dir, _}` — `project_dir` is not a real directory
  """
  @spec safe_resolve(project_dir(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def safe_resolve(project_dir, rel_path)
      when is_binary(project_dir) and is_binary(rel_path) do
    cond do
      rel_path == "" ->
        {:error, :invalid_argument}

      Path.type(rel_path) == :absolute ->
        {:error, :invalid_argument}

      true ->
        with {:ok, root_real} <- realpath(project_dir, :invalid_project_dir) do
          joined = Path.expand(rel_path, root_real)
          # Don't require the file to exist yet (we may be writing it).
          # Use realpath of the deepest existing ancestor instead.
          ancestor_real = realpath_existing_ancestor(joined)

          if path_under?(ancestor_real, root_real) do
            {:ok, joined}
          else
            {:error, :escape}
          end
        end
    end
  end

  def safe_resolve(_, _), do: {:error, :invalid_argument}

  @doc """
  Atomically write `content` to `abs_path`. Creates parent dirs as
  needed. Writes to a sibling temp file then `File.rename/2`s it into
  place so a watcher never sees a partial file.
  """
  @spec write_atomic(String.t(), iodata()) :: :ok | {:error, term()}
  def write_atomic(abs_path, content) when is_binary(abs_path) do
    with :ok <- File.mkdir_p(Path.dirname(abs_path)),
         tmp = abs_path <> "." <> rand_suffix() <> ".tmp",
         :ok <- File.write(tmp, content),
         :ok <- File.rename(tmp, abs_path) do
      :ok
    else
      {:error, _} = err -> err
    end
  end

  @doc """
  List entries directly under `abs_dir`. Returns
  `{:ok, [%{name, type, size}]}` where `type` is `:file | :dir | :other`.
  """
  @spec list_entries(String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_entries(abs_dir) when is_binary(abs_dir) do
    case File.ls(abs_dir) do
      {:ok, names} ->
        entries =
          names
          |> Enum.sort()
          |> Enum.map(fn name ->
            full = Path.join(abs_dir, name)

            case File.stat(full) do
              {:ok, %File.Stat{type: :regular, size: size}} ->
                %{name: name, type: :file, size: size}

              {:ok, %File.Stat{type: :directory}} ->
                %{name: name, type: :dir, size: 0}

              {:ok, %File.Stat{}} ->
                %{name: name, type: :other, size: 0}

              {:error, _} ->
                %{name: name, type: :other, size: 0}
            end
          end)

        {:ok, entries}

      {:error, _} = err ->
        err
    end
  end

  defp realpath(path, error_tag) do
    expanded = Path.expand(path)

    case File.exists?(expanded) do
      true ->
        # `Path.expand` doesn't follow symlinks; use the OS's realpath
        # via `:filelib.find_file/2` analog. Elixir doesn't ship a
        # realpath, so we use a small File.read_link loop.
        {:ok, follow_symlinks(expanded)}

      false ->
        {:error, {error_tag, expanded}}
    end
  end

  defp follow_symlinks(path) do
    case File.read_link(path) do
      {:ok, target} ->
        absolute_target =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.expand(target, Path.dirname(path))

        follow_symlinks(absolute_target)

      {:error, _} ->
        path
    end
  end

  # Walk up from `path` until we hit an existing ancestor; return its
  # realpath. Used for paths we're about to create.
  defp realpath_existing_ancestor(path) do
    cond do
      File.exists?(path) ->
        follow_symlinks(path)

      path in ["/", ""] ->
        path

      true ->
        realpath_existing_ancestor(Path.dirname(path))
    end
  end

  defp path_under?(child, parent) do
    child = String.trim_trailing(child, "/")
    parent = String.trim_trailing(parent, "/")
    child == parent or String.starts_with?(child, parent <> "/")
  end

  defp rand_suffix do
    :crypto.strong_rand_bytes(6) |> Base.url_encode64(padding: false)
  end
end
