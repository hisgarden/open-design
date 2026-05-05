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

  Options:
    * `:model`  — model id; falls back to `@default_model`.
    * `:images` — list of image references attached to the prompt.
                  Each entry is one of:
                    * `%{"url" => "https://..."}` — remote URL (or any `data:` URL)
                    * `%{"base64" => "...", "mime" => "image/png"}` — inlined bytes
                  When present, the user message is sent as an OpenAI
                  multimodal `content` array (`[{type: "text"}, {type: "image_url"}, ...]`)
                  so vision-language models like `Qwen/Qwen3-VL-235B-A22B-Instruct`
                  can ground on the attached images.
    * `:system` — optional system prompt prepended to the messages array.
                  Composed by `BeamDesign.Agents.PromptComposer` from the
                  active skill + design system; nil when neither is set.
  """
  @spec start(pid(), String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start(parent, prompt, opts \\ []) when is_pid(parent) and is_binary(prompt) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        model = Keyword.get(opts, :model) || @default_model
        images = Keyword.get(opts, :images, []) |> List.wrap()
        system = Keyword.get(opts, :system)
        Task.start_link(fn -> stream(parent, key, model, prompt, images, system) end)
    end
  end

  @doc """
  Run one tool-loop turn. Caller supplies the full message history
  (system + user + prior assistant tool_calls + tool results); we send
  it as-is, advertise `tools` if non-empty, and stream events back to
  `parent` until the model produces a `finish_reason`.

  Sends to parent (each turn):
    * `{:agent_chunk, text}`              — text delta
    * `{:agent_tool_calls, calls}`        — when finish_reason == "tool_calls".
                                            `calls` is a list of
                                            `%{id, name, arguments}` (arguments
                                             are the raw JSON string the model
                                             emitted; caller decodes)
    * `{:agent_turn_done, %{finish_reason}}` — every turn ends with this
                                                (finish_reason: "stop" |
                                                 "tool_calls" | "length" | ...)
    * `{:agent_done, %{success: bool, error?: String.t()}}` — only on
      transport / 4xx / 5xx failure. Successful turns send `:agent_turn_done`
      and let the caller decide whether to start another turn.

  Options:
    * `:model`  — DeepInfra model id; required.
    * `:tools`  — list of OpenAI tool definitions (see `BeamDesign.Agents.Tools.definitions/0`).
                  Empty / missing means no tool calling.
  """
  @spec start_turn(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  def start_turn(parent, opts) when is_pid(parent) do
    case api_key() do
      nil ->
        {:error, :missing_api_key}

      key ->
        messages = Keyword.fetch!(opts, :messages)
        model = Keyword.get(opts, :model) || @default_model
        tools = Keyword.get(opts, :tools, [])
        Task.start_link(fn -> stream_turn(parent, key, model, messages, tools) end)
    end
  end

  defp stream(parent, api_key, model, prompt, images, system) do
    user_msg = %{role: "user", content: build_content(prompt, images)}

    messages =
      case system do
        s when is_binary(s) and s != "" -> [%{role: "system", content: s}, user_msg]
        _ -> [user_msg]
      end

    body = %{
      model: model,
      stream: true,
      messages: messages
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

  # One tool-loop turn. Streams text deltas to `parent`, accumulates
  # tool_call argument fragments, and on finish_reason emits the
  # appropriate terminal message: `{:agent_tool_calls, ...}` if the
  # model wants to call tools, then always a `{:agent_turn_done, ...}`
  # so the caller can decide whether to start the next turn.
  defp stream_turn(parent, api_key, model, messages, tools) do
    body =
      %{model: model, stream: true, messages: messages}
      |> maybe_put_tools(tools)

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "text/event-stream"}
    ]

    # Two stateful accumulators in resp.private:
    #   :sse_buffer    — leftover bytes between SSE frames
    #   :tool_calls    — %{index => %{id, name, arguments_io}} where
    #                    arguments_io is an IO list of chunks (joined
    #                    once at finish_reason time)
    into = fn {:data, chunk}, {req, resp} ->
      buffer = (Map.get(resp.private, :sse_buffer) || "") <> chunk
      {events, leftover} = parse_sse_buffer(buffer)
      tool_calls = Map.get(resp.private, :tool_calls) || %{}

      tool_calls = Enum.reduce(events, tool_calls, &handle_event(parent, &1, &2))

      resp =
        resp
        |> Req.Response.put_private(:sse_buffer, leftover)
        |> Req.Response.put_private(:tool_calls, tool_calls)

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
        # If the stream ended without a finish_reason fire, synthesize
        # a turn_done so the RunServer doesn't hang. Some providers cut
        # SSE off after the last delta without emitting an empty frame
        # carrying finish_reason.
        unless Process.get(:finish_emitted) == true do
          require Logger
          Logger.warning("[deep_infra] stream ended without finish_reason; synthesizing :agent_turn_done")
          send(parent, {:agent_turn_done, %{finish_reason: "stop"}})
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        require Logger
        Logger.error("[deep_infra] HTTP #{status} from DeepInfra: #{inspect(body)}")
        send(parent, {:agent_done, %{success: false, error: "HTTP #{status}: #{inspect(body)}"}})

      {:error, exception} ->
        require Logger
        Logger.error("[deep_infra] transport error: #{Exception.message(exception)}")
        send(parent, {:agent_done, %{success: false, error: Exception.message(exception)}})
    end
  end

  defp maybe_put_tools(body, []), do: body
  defp maybe_put_tools(body, nil), do: body
  defp maybe_put_tools(body, tools) when is_list(tools), do: Map.put(body, :tools, tools)

  # Per-event handler for stream_turn. Mutates the tool_calls accumulator,
  # streams text deltas, and on `:finish` emits the consolidated
  # `:agent_tool_calls` (when reason == "tool_calls") followed by an
  # `:agent_turn_done` so the caller knows the turn ended.
  defp handle_event(parent, {:delta, text}, acc) do
    send(parent, {:agent_chunk, text})
    acc
  end

  defp handle_event(_parent, {:tool_call_delta, %{index: index} = frag}, acc) do
    current =
      Map.get(acc, index, %{id: nil, name: nil, arguments_io: []})

    updated = %{
      id: frag.id || current.id,
      name: frag.name || current.name,
      arguments_io:
        case frag.arguments_chunk do
          chunk when is_binary(chunk) -> [current.arguments_io, chunk]
          _ -> current.arguments_io
        end
    }

    Map.put(acc, index, updated)
  end

  defp handle_event(parent, {:finish, reason}, acc) do
    case reason do
      "tool_calls" ->
        calls =
          acc
          |> Enum.sort_by(fn {idx, _} -> idx end)
          |> Enum.map(fn {idx, c} ->
            # Qwen3-Max and some other DeepInfra-hosted models stream
            # tool_calls without an `id` field. Without an id, the
            # tool_result message we feed back can't be correlated by
            # the model, and it loops on the same call. Synthesize a
            # stable id when missing.
            id =
              case c.id do
                s when is_binary(s) and s != "" -> s
                _ -> "call_synth_#{idx}_#{System.unique_integer([:positive])}"
              end

            %{
              id: id,
              name: c.name,
              arguments: IO.iodata_to_binary(c.arguments_io)
            }
          end)

        send(parent, {:agent_tool_calls, calls})

      _ ->
        :ok
    end

    send(parent, {:agent_turn_done, %{finish_reason: reason}})
    Process.put(:finish_emitted, true)
    acc
  end

  defp handle_event(_parent, _other, acc), do: acc

  defp api_key do
    System.get_env("DEEPINFRA_API_KEY") || System.get_env("OD_DEEPINFRA_API_KEY")
  end

  # Build the OpenAI `content` field. With no images, send the plain string
  # form (cheaper to encode, identical semantics for text-only models).
  # With images, switch to the multimodal content-array form so vision-
  # language models receive the image alongside the text.
  defp build_content(prompt, []), do: prompt

  defp build_content(prompt, images) do
    image_blocks =
      images
      |> Enum.flat_map(&image_block/1)

    [%{type: "text", text: prompt} | image_blocks]
  end

  defp image_block(%{"url" => url}) when is_binary(url) and url != "" do
    [%{type: "image_url", image_url: %{url: url}}]
  end

  defp image_block(%{"base64" => b64, "mime" => mime}) when is_binary(b64) and is_binary(mime) do
    [%{type: "image_url", image_url: %{url: "data:#{mime};base64,#{b64}"}}]
  end

  defp image_block(%{"base64" => b64}) when is_binary(b64) do
    image_block(%{"base64" => b64, "mime" => "image/png"})
  end

  defp image_block(_), do: []

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
      {:ok, %{"choices" => [choice | _]}} ->
        delta = Map.get(choice, "delta") || %{}

        events =
          []
          |> append_content(Map.get(delta, "content"))
          |> append_tool_call_deltas(Map.get(delta, "tool_calls"))
          |> append_finish(Map.get(choice, "finish_reason"))

        if events == [], do: [:other], else: events

      _ ->
        [:other]
    end
  end

  defp parse_data_line(_), do: []

  defp append_content(events, c) when is_binary(c) and c != "",
    do: events ++ [{:delta, c}]

  defp append_content(events, _), do: events

  defp append_tool_call_deltas(events, calls) when is_list(calls) do
    events ++
      Enum.map(calls, fn call ->
        function = Map.get(call, "function") || %{}

        {:tool_call_delta,
         %{
           index: Map.get(call, "index"),
           id: Map.get(call, "id"),
           name: Map.get(function, "name"),
           arguments_chunk: Map.get(function, "arguments")
         }}
      end)
  end

  defp append_tool_call_deltas(events, _), do: events

  defp append_finish(events, reason) when is_binary(reason) and reason != "",
    do: events ++ [{:finish, reason}]

  defp append_finish(events, _), do: events
end
