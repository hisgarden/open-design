defmodule BeamDesign.Auth.Token do
  @moduledoc """
  Bearer-token mint, file persistence (mode 0600), and timing-safe verify.

  Forward-applied from the open-design audit (R18 / R19 / AE3): the daemon
  binds only to loopback, and every mutating protocol surface requires the
  bearer token from the file the launcher writes at startup.
  """

  @doc """
  Generate a fresh 256-bit hex token.
  """
  @spec mint() :: String.t()
  def mint, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  @doc """
  Write the token to `path` with mode 0600. Parent dir created with mode 0700
  if absent. Returns `:ok` or `{:error, reason}`.
  """
  @spec write(Path.t(), String.t()) :: :ok | {:error, term()}
  def write(path, token) when is_binary(path) and is_binary(token) do
    dir = Path.dirname(path)
    dir_existed_before? = File.dir?(dir)

    with :ok <- File.mkdir_p(dir),
         :ok <- maybe_chmod_dir(dir, dir_existed_before?),
         :ok <- File.write(path, token, [:binary]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  # Only tighten the directory's mode when we created it. Don't try to
  # chmod a pre-existing directory we may not own (e.g., /tmp).
  defp maybe_chmod_dir(_dir, true), do: :ok
  defp maybe_chmod_dir(dir, false), do: File.chmod(dir, 0o700)

  @doc """
  Read the token from `path`. Returns `{:ok, token}` or `{:error, reason}`.
  """
  @spec read(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read(path), do: File.read(path)

  @doc """
  Constant-time comparison of two tokens.
  """
  @spec verify(String.t(), String.t()) :: boolean()
  def verify(expected, candidate)
      when is_binary(expected) and is_binary(candidate) do
    Plug.Crypto.secure_compare(expected, candidate)
  end

  def verify(_, _), do: false
end
