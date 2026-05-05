defmodule BeamDesign.Agents.Tools do
  @moduledoc """
  OpenAI-compatible tool definitions + execution surface for BEAM agents.

  Three tools, scoped to one project directory:

    * `write_file(path, content)` — atomic create-or-replace
    * `read_file(path)` — read existing file
    * `list_files(dir)` — list immediate children of a directory

  All path arguments are strings relative to the run's `project_dir`.
  Resolution + escape-detection is delegated to
  `BeamDesign.Workspace.Sandbox.safe_resolve/2`.

  Pure data + pure functions. No GenServer state. Callers (the
  RunServer) own the loop and the message history.
  """

  alias BeamDesign.Workspace.Sandbox

  @typedoc "OpenAI tool definitions; encoded into the chat completion `tools:` array."
  @type definitions :: [map()]

  @doc """
  The static OpenAI tool list to send with each chat-completion request
  during a tool-loop turn. Stable shape — the model sees the same
  definitions every turn so it can plan multi-call sequences.
  """
  @spec definitions() :: definitions()
  def definitions do
    [
      %{
        type: "function",
        function: %{
          name: "write_file",
          description:
            "Create or overwrite a file under the project directory. Path is relative to the project root. Use this to emit slides, stylesheets, scripts — every artifact the user will see in the preview pane.",
          parameters: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description:
                  "File path relative to the project root (no leading slash). Examples: index.html, assets/theme.css, slides/slide-1.html."
              },
              content: %{
                type: "string",
                description: "Full file contents as a UTF-8 string."
              }
            },
            required: ["path", "content"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "read_file",
          description:
            "Read an existing file under the project directory. Use to inspect skill seed templates the active skill references (e.g. assets/template.html) before writing your own output.",
          parameters: %{
            type: "object",
            properties: %{
              path: %{
                type: "string",
                description: "File path relative to the project root."
              }
            },
            required: ["path"]
          }
        }
      },
      %{
        type: "function",
        function: %{
          name: "list_files",
          description:
            "List the immediate entries (files and subdirectories) under a directory in the project. Pass dir=\".\" for the project root.",
          parameters: %{
            type: "object",
            properties: %{
              dir: %{
                type: "string",
                description: "Directory path relative to the project root. Use \".\" for the root."
              }
            },
            required: ["dir"]
          }
        }
      }
    ]
  end

  @doc """
  Execute one tool call against the project sandbox.

  `name` is the function name the model emitted; `arguments` is the
  already-decoded JSON object the model emitted as `function.arguments`.
  Returns a JSON-serializable map shaped as the `content` of an OpenAI
  `role: "tool"` reply.

  All errors come back structured (`%{error: <reason>}`) so the model
  gets a chance to recover (try a different path, list_files first,
  etc.) instead of seeing a generic transport failure.
  """
  @spec execute(String.t(), map(), String.t()) :: map()
  def execute("write_file", args, project_dir) do
    with {:ok, path} <- fetch_string(args, "path"),
         {:ok, content} <- fetch_content(args),
         {:ok, abs} <- Sandbox.safe_resolve(project_dir, path),
         :ok <- Sandbox.write_atomic(abs, content) do
      %{ok: true, path: path, bytes: byte_size(content)}
    else
      {:error, reason} -> %{error: format_error(reason)}
    end
  end

  def execute("read_file", args, project_dir) do
    with {:ok, path} <- fetch_string(args, "path"),
         {:ok, abs} <- Sandbox.safe_resolve(project_dir, path),
         {:ok, content} <- File.read(abs) do
      %{ok: true, path: path, content: content}
    else
      {:error, reason} -> %{error: format_error(reason)}
    end
  end

  def execute("list_files", args, project_dir) do
    rel =
      case Map.get(args, "dir", ".") do
        s when is_binary(s) and s != "" -> s
        _ -> "."
      end

    with {:ok, abs} <- Sandbox.safe_resolve(project_dir, rel),
         {:ok, entries} <- Sandbox.list_entries(abs) do
      %{ok: true, dir: rel, entries: entries}
    else
      {:error, reason} -> %{error: format_error(reason)}
    end
  end

  def execute(other, _args, _project_dir) do
    %{error: "unknown tool: #{inspect(other)}"}
  end

  defp fetch_string(args, key) do
    case Map.get(args, key) do
      s when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:error, {:missing_arg, key}}
    end
  end

  # `write_file`'s `content` may legitimately be empty (e.g. truncating
  # a file). Distinguish "key missing entirely" from "explicitly empty".
  defp fetch_content(args) do
    case Map.fetch(args, "content") do
      {:ok, s} when is_binary(s) -> {:ok, s}
      _ -> {:error, {:missing_arg, "content"}}
    end
  end

  defp format_error({:missing_arg, key}), do: "missing or empty argument: #{key}"
  defp format_error(:invalid_argument), do: "invalid path argument"
  defp format_error(:escape), do: "path escapes the project sandbox"
  defp format_error({:invalid_project_dir, p}), do: "project directory not found: #{p}"
  defp format_error(:enoent), do: "file not found"
  defp format_error(:eacces), do: "permission denied"
  defp format_error(other), do: inspect(other)
end
