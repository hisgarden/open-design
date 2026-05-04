defmodule BeamDesign.Auth.Holder do
  @moduledoc """
  Holds the current process-lifetime auth token in memory so the channel
  layer can verify against it without a per-request file read on the hot path.

  Started by `BeamDesign.Application` after minting the token at boot.
  """
  use GenServer

  alias BeamDesign.Auth.Token

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the current in-memory token."
  @spec current() :: String.t()
  def current, do: GenServer.call(__MODULE__, :current)

  @doc "Verify a candidate token against the in-memory one."
  @spec verify(String.t() | nil) :: boolean()
  def verify(nil), do: false
  def verify(candidate), do: Token.verify(current(), candidate)

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path) || token_path_from_config()
    token = Keyword.get(opts, :token) || Token.mint()

    case Token.write(path, token) do
      :ok -> {:ok, %{path: path, token: token}}
      {:error, reason} -> {:stop, {:token_write_failed, reason}}
    end
  end

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state.token, state}

  defp token_path_from_config do
    Application.get_env(:beam_design, :auth_token_path) ||
      Path.expand("~/.beam-design/auth-token")
  end
end
