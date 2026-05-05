defmodule BeamDesign.Auth.DaemonId do
  @moduledoc """
  Stable per-install UUID for the daemon.

  Multi-client deduplication: when the React UI, future desktop app,
  and any third-party client all connect to the same loopback daemon,
  they should all see the same `daemon_id`. Without one, each
  connection looks like a fresh runtime to whatever client-side
  inventory layer cares (multica brief #2 — "is this the same
  daemon I was talking to before?").

  Persisted at `~/.beam-design/daemon.id` (mode 0600). Survives
  hostname `.local` drift, mDNS state changes, profile renames. If
  missing or unparseable on startup, a fresh UUID is minted and
  written atomically (temp + rename) so a daemon-crash-mid-write
  doesn't leave a half-written file.

  Cached in `:persistent_term` after first ensure so subsequent
  `current/0` calls are lock-free.
  """

  @env_override "BEAM_DESIGN_DAEMON_ID_PATH"
  @persistent_key __MODULE__

  @doc """
  Read the cached daemon id, ensuring it's loaded if not yet.
  Idempotent. Called from `BeamDesign.Application.start/2` and from
  the channel's welcome push.
  """
  @spec current() :: String.t()
  def current do
    case :persistent_term.get(@persistent_key, nil) do
      id when is_binary(id) and id != "" -> id
      _ -> ensure_loaded()
    end
  end

  @doc """
  Force a re-read from disk. Test-only — production callers use
  `current/0`. Returns the loaded id.
  """
  @spec reload!() :: String.t()
  def reload! do
    :persistent_term.erase(@persistent_key)
    ensure_loaded()
  end

  @doc """
  Resolve the on-disk path. Honors `BEAM_DESIGN_DAEMON_ID_PATH` for
  test isolation; falls back to `~/.beam-design/daemon.id`.
  """
  @spec path() :: Path.t()
  def path do
    case System.get_env(@env_override) do
      p when is_binary(p) and p != "" -> p
      _ -> Path.expand("~/.beam-design/daemon.id")
    end
  end

  # ------------------------------------------------------------------

  defp ensure_loaded do
    p = path()

    id =
      case File.read(p) do
        {:ok, raw} ->
          parsed = String.trim(raw)

          if valid_uuid?(parsed) do
            parsed
          else
            mint_and_write(p)
          end

        {:error, _} ->
          mint_and_write(p)
      end

    :persistent_term.put(@persistent_key, id)
    id
  end

  defp mint_and_write(p) do
    File.mkdir_p!(Path.dirname(p))

    id = mint_uuid()

    # Atomic write: write to a sibling temp file then rename. Avoids
    # exposing a half-written file if the daemon crashes mid-write.
    tmp = p <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false) <> ".tmp"
    File.write!(tmp, id <> "\n")
    File.chmod!(tmp, 0o600)
    File.rename!(tmp, p)
    id
  end

  defp valid_uuid?(s) when is_binary(s) do
    # Accept any well-formed 8-4-4-4-12 hex UUID. We mint v4 below
    # but tolerate any version an operator may have pre-seeded.
    Regex.match?(~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i, s)
  end

  defp valid_uuid?(_), do: false

  # Mint a standard UUID v4 (122 random bits + version + variant).
  # We don't need v7's time-ordering for daemon identity — any random
  # 128-bit id is sufficient for "is this the same install".
  defp mint_uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)
    # Set version 4 (top 4 bits of `c`) and RFC 4122 variant (top 2 bits of `d`).
    c = c |> Bitwise.band(0x0FFF) |> Bitwise.bor(0x4000)
    d = d |> Bitwise.band(0x3FFF) |> Bitwise.bor(0x8000)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map(fn {n, w} -> n |> Integer.to_string(16) |> String.pad_leading(w, "0") end)
    |> Enum.join("-")
    |> String.downcase()
  end
end
