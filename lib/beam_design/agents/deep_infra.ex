defmodule BeamDesign.Agents.DeepInfra do
  @moduledoc """
  Adapter for DeepInfra's OpenAI-compatible chat-completions API.

  Streams via SSE to a calling RunServer pid. Each text delta is delivered
  as `{:agent_chunk, String.t()}`; terminal as
  `{:agent_done, %{success: bool, error?: String.t() | nil, usage?: map()}}`.

  Auth: reads `DEEPINFRA_API_KEY` (or `OD_DEEPINFRA_API_KEY`) from env.
  """

  @endpoint "https://api.deepinfra.com/v1/openai/chat/completions"
  @default_model "meta-llama/Meta-Llama-3.1-8B-Instruct"

  @doc """
  Spawn a linked task that streams a chat completion to `parent`.

  Sends to parent:
    * `{:agent_chunk, text}` — one or more text deltas
    * `{:agent_done, %{success: bool, ...}}` — terminal
  """
  @spec start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(parent, prompt, opts \\ []) when is_pid(parent) and is_binary(prompt) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        model = Keyword.get(opts, :model) || @default_model
        Task.start_link(fn -> stream(parent, key, model, prompt) end)
    end
  end

  defp stream(parent, api_key, model, prompt) do
    body = %{
      model: model,
      stream: true,
      messages: [%{role: "user", content: prompt}]
    }

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    # Buffer SSE bytes across chunks. Req's :into callback receives the
    # current Req.Response as the accumulator; we stash leftover partial
    # SSE in resp.private[:sse_buffer].
    into = fn {:data, chunk}, {req, resp} ->
      buffer = (Map.get(resp.private, :sse_buffer) || "") <> chunk
      {events, leftover} = parse_sse_buffer(buffer)

      for ev <- events do
        case ev do
          {:delta, text} -> send(parent, {:agent_chunk, text})
          _ -> :ok
        end
      end

      resp = Req.Response.put_private(resp, :sse_buffer, leftover)
      {:cont, {req, resp}}
    end

    result =
      Req.post(@endpoint,
        json: body,
        headers: headers,
        receive_timeout: 60_000,
        connect_options: connect_options(),
        into: into
      )

    case result do
      {:ok, %Req.Response{status: 200}} ->
        send(parent, {:agent_done, %{success: true}})

      {:ok, %Req.Response{status: status, body: body}} ->
        send(parent, {:agent_done, %{success: false, error: "HTTP #{status}: #{inspect(body)}"}})

      {:error, exception} ->
        send(parent, {:agent_done, %{success: false, error: Exception.message(exception)}})
    end
  end

  defp api_key do
    System.get_env("DEEPINFRA_API_KEY") || System.get_env("OD_DEEPINFRA_API_KEY")
  end

  # Build Finch/Mint connection options honoring HTTPS_PROXY (e.g. the
  # OneCLI local gateway at localhost:10255 that intercepts outbound
  # 443 from non-allowlisted processes) and trusting the gateway's CA
  # from NODE_EXTRA_CA_CERTS or ~/.onecli/gateway/ca.pem when present.
  defp connect_options do
    base = [
      timeout: 15_000,
      transport_opts: [
        cacerts: :public_key.cacerts_get() ++ extra_cas(),
        verify: :verify_peer,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ]
    ]

    case parse_https_proxy() do
      nil ->
        base

      {scheme, host, port, basic_auth} ->
        proxy_extra =
          [
            proxy: {scheme, host, port, []}
          ] ++
            if(basic_auth,
              do: [proxy_headers: [{"proxy-authorization", "Basic #{basic_auth}"}]],
              else: []
            )

        Keyword.merge(base, proxy_extra)
    end
  end

  defp parse_https_proxy do
    case System.get_env("HTTPS_PROXY") || System.get_env("HTTP_PROXY") do
      nil ->
        nil

      url ->
        uri = URI.parse(url)
        scheme = if uri.scheme == "https", do: :https, else: :http
        port = uri.port || if(scheme == :https, do: 443, else: 80)

        basic =
          case uri.userinfo do
            nil -> nil
            "" -> nil
            ui -> Base.encode64(ui)
          end

        if uri.host && port, do: {scheme, uri.host, port, basic}, else: nil
    end
  end

  defp extra_cas do
    candidates =
      [
        System.get_env("NODE_EXTRA_CA_CERTS"),
        Path.expand("~/.onecli/gateway/ca.pem"),
        "/tmp/onecli-gateway-ca.pem"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    candidates
    |> Enum.flat_map(fn path ->
      case File.read(path) do
        {:ok, pem} ->
          pem
          |> :public_key.pem_decode()
          |> Enum.flat_map(fn
            {:Certificate, der, _} -> [der]
            _ -> []
          end)

        {:error, _} ->
          []
      end
    end)
  end

  @doc """
  Parse a buffer of SSE bytes into completed events plus any leftover
  partial data. Each completed event is one of:
    * `{:delta, String.t()}` — a content delta extracted from `data: {...}`
    * `{:done, nil}` — terminal `data: [DONE]` sentinel
    * `:other` — non-content event we ignored
  """
  @spec parse_sse_buffer(String.t()) :: {[term()], String.t()}
  def parse_sse_buffer(buffer) do
    # SSE events are separated by blank lines (\n\n). Split, keep the
    # final partial event in `leftover`.
    parts = String.split(buffer, "\n\n")
    {complete, [tail]} = Enum.split(parts, -1)

    events =
      complete
      |> Enum.flat_map(&parse_one_event/1)

    {events, tail}
  end

  defp parse_one_event(raw) do
    raw
    |> String.split("\n")
    |> Enum.flat_map(&parse_data_line/1)
  end

  defp parse_data_line("data: [DONE]"), do: [{:done, nil}]

  defp parse_data_line("data: " <> json) do
    case Jason.decode(json) do
      {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) ->
        [{:delta, content}]

      _ ->
        [:other]
    end
  end

  defp parse_data_line(_), do: []
end
