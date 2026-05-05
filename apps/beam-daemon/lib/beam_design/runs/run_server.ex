defmodule BeamDesign.Runs.RunServer do
  @moduledoc """
  Per-run GenServer. Owns the Port (for CLI agents) or HTTP task (for
  network agents) for one active run; forwards normalized events to the
  subscribing channel pid; records terminal status.

  v1 design: the channel passes its own pid to start_link so events
  arrive as direct messages. PubSub-based delivery (channel-reconnect-
  surviving) is a future refactor.
  """
  use GenServer, restart: :transient

  alias BeamDesign.Agents.{ClaudeCode, DeepInfra, PromptComposer, Tools}
  alias BeamDesign.Conversations
  alias BeamDesign.{DesignSystems, Skills}

  # Sliding-window cap on conversation message history. ~200 entries
  # is comfortable for DeepSeek V4-Pro's 128K context (each entry
  # averages 1-3KB). When we hit the cap, keep the very first message
  # (the system prompt + skill body, which is load-bearing) plus the
  # last (cap - 1) entries — the recent conversation. Older middle
  # turns get dropped.
  @max_persisted_messages 200

  @max_tool_iterations 10

  defmodule State do
    @moduledoc false
    defstruct [
      :run_id,
      :subscriber,
      :agent,
      :port,
      :payload,
      :started_at,
      :line_buffer,
      :line_count,
      :terminal?,
      # DeepInfra tool-loop state. Nil for non-deepinfra agents.
      :model,
      :messages,
      :project_dir,
      :tool_iterations,
      # Conversation-resumption keys (Phase 4A). Both nil for runs not
      # tagged with a conversation_id; behavior changes only when both
      # are populated AND the agent path supports it (Phase 4C wires
      # this in for deepinfra). workspace_id comes from the channel's
      # authenticated socket, NOT the bridge payload.
      :workspace_id,
      :conversation_id
    ]
  end

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(opts),
    do: %{id: opts.run_id, start: {__MODULE__, :start_link, [opts]}, restart: :transient}

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(%{run_id: run_id, subscriber: subscriber, payload: payload} = opts) do
    Process.flag(:trap_exit, true)
    agent = Map.get(opts, :agent, "claude-code")

    state = %State{
      run_id: run_id,
      subscriber: subscriber,
      agent: agent,
      payload: payload,
      started_at: System.system_time(:millisecond),
      line_buffer: "",
      line_count: 0,
      terminal?: false,
      model: nil,
      messages: [],
      project_dir: nil,
      tool_iterations: 0,
      workspace_id: payload["workspace_id"],
      conversation_id: payload["conversation_id"]
    }

    case dispatch_agent(agent, payload, state) do
      {:ok, {owner_ref, state2}} ->
        send_event(state2, "run.started", %{
          run_id: run_id,
          agent: agent,
          model: state2.model || payload["model"],
          started_at: state2.started_at
        })

        {:ok, %{state2 | port: owner_ref}}

      {:error, reason} ->
        send_event(state, "run.terminal", %{
          run_id: run_id,
          status: "failed",
          exit: -1,
          error: inspect(reason),
          ended_at: System.system_time(:millisecond)
        })

        {:stop, :normal}
    end
  end

  # DeepInfra streaming events.
  #
  # - `{:agent_chunk, text}` — a content delta; relay as run.output.
  # - `{:agent_tool_calls, calls}` — model wants to call tools. Execute
  #   each, append (assistant tool_calls + tool result) to history, kick
  #   off the next turn. Only fires when `:agent_turn_done` reason ==
  #   "tool_calls".
  # - `{:agent_turn_done, %{finish_reason}}` — every turn ends with this.
  #   "stop" / "length" → emit run.terminal. "tool_calls" → no-op
  #   (next turn already started in :agent_tool_calls handler).
  # - `{:agent_done, %{success: false, ...}}` — only on transport failure
  #   (4xx/5xx, connection refused). Always terminates the run.
  @impl true
  def handle_info({:agent_chunk, text}, state) when is_binary(text) do
    send_event(state, "run.output", %{run_id: state.run_id, kind: "agent", delta: text})
    {:noreply, state}
  end

  def handle_info({:agent_tool_calls, calls}, state) when is_list(calls) do
    if state.tool_iterations >= @max_tool_iterations do
      send_event(state, "run.terminal", %{
        run_id: state.run_id,
        status: "failed",
        exit: -1,
        error: "max_tool_iterations (#{@max_tool_iterations}) exceeded",
        ended_at: System.system_time(:millisecond)
      })

      {:stop, :normal, %{state | terminal?: true}}
    else
      assistant_tool_calls_msg = build_assistant_tool_calls_message(calls)

      tool_result_msgs =
        Enum.map(calls, fn call ->
          execute_and_emit_tool_call(state, call)
        end)

      new_messages = state.messages ++ [assistant_tool_calls_msg] ++ tool_result_msgs
      next_state = %{state | messages: new_messages, tool_iterations: state.tool_iterations + 1}

      # Snapshot mid-conversation so a daemon crash or run cancel
      # between turns leaves a recoverable trace. Multica calls this
      # "early pinning"; cheap because the store is in-memory.
      persist_messages(next_state)

      case start_deepinfra_turn(next_state) do
        {:ok, _} ->
          {:noreply, next_state}

        {:error, reason} ->
          send_event(state, "run.terminal", %{
            run_id: state.run_id,
            status: "failed",
            exit: -1,
            error: inspect(reason),
            ended_at: System.system_time(:millisecond)
          })

          {:stop, :normal, %{state | terminal?: true}}
      end
    end
  end

  def handle_info({:agent_turn_done, %{finish_reason: "tool_calls"}}, state) do
    # The :agent_tool_calls handler already started the next turn.
    {:noreply, state}
  end

  def handle_info({:agent_turn_done, %{finish_reason: reason}}, state) do
    # "stop" | "length" | other — terminal for a non-tool-calling turn.
    status = if reason == "stop", do: "succeeded", else: "failed"

    terminal_payload =
      %{
        run_id: state.run_id,
        status: status,
        exit: if(status == "succeeded", do: 0, else: 1),
        finish_reason: reason,
        ended_at: System.system_time(:millisecond)
      }

    # Final persist: capture the run's full message history before the
    # GenServer dies, so the next run on this conversation_id can pick
    # up exactly where this one left off.
    persist_messages(state)

    send_event(state, "run.terminal", terminal_payload)
    {:stop, :normal, %{state | terminal?: true}}
  end

  def handle_info({:agent_done, %{success: success} = result}, state) do
    terminal_payload =
      %{
        run_id: state.run_id,
        status: if(success, do: "succeeded", else: "failed"),
        exit: if(success, do: 0, else: 1),
        ended_at: System.system_time(:millisecond)
      }
      |> maybe_put(:error, Map.get(result, :error))

    send_event(state, "run.terminal", terminal_payload)
    {:stop, :normal, %{state | terminal?: true}}
  end

  # ClaudeCode (port-based) streaming events. The deepinfra path is
  # task-based and uses the :agent_* messages above.

  def handle_info({port, {:data, {flag, line}}}, %State{port: {:port, port}} = state) do
    full_line =
      case flag do
        :eol -> state.line_buffer <> line
        :noeol -> state.line_buffer <> line
      end

    state = %{state | line_buffer: ""}

    state =
      case flag do
        :noeol ->
          %{state | line_buffer: full_line}

        :eol ->
          handle_complete_line(full_line, %{state | line_count: state.line_count + 1})
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %State{port: {:port, port}} = state) do
    if state.terminal? do
      {:stop, :normal, state}
    else
      send_event(state, "run.terminal", %{
        run_id: state.run_id,
        status: if(status == 0, do: "succeeded", else: "failed"),
        exit: status,
        ended_at: System.system_time(:millisecond)
      })

      {:stop, :normal, %{state | terminal?: true}}
    end
  end

  def handle_info({:EXIT, port, _reason}, %State{port: {:port, port}} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, pid, _reason}, %State{port: {:task, pid}} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Build the OpenAI-shape `role: "assistant", tool_calls: [...]` message
  # we have to send back to the API on the next turn so the model can
  # follow its own thread.
  # OpenAI's spec allows `content: null` here, but several
  # OpenAI-compatible providers (including some DeepInfra-hosted
  # variants) reject the null and silently drop the request. Send an
  # empty string instead — semantically identical, universally accepted.
  defp build_assistant_tool_calls_message(calls) do
    %{
      role: "assistant",
      content: "",
      tool_calls:
        Enum.map(calls, fn c ->
          %{
            id: c.id,
            type: "function",
            function: %{
              name: c.name,
              arguments: c.arguments
            }
          }
        end)
    }
  end

  # Execute one tool call against the project sandbox, emit
  # `run.tool_use` + `run.tool_result` channel events for UI surfacing,
  # and return the corresponding `role: "tool"` message to feed back
  # into the next turn's request.
  defp execute_and_emit_tool_call(state, %{id: id, name: name, arguments: args_json}) do
    args =
      case Jason.decode(args_json || "") do
        {:ok, %{} = m} -> m
        _ -> %{}
      end

    send_event(state, "run.tool_use", %{
      run_id: state.run_id,
      id: id,
      name: name,
      input: args
    })

    result_map =
      try do
        Tools.execute(name, args, state.project_dir || "")
      rescue
        e -> %{error: "tool_exception: #{Exception.message(e)}"}
      end

    is_error = Map.has_key?(result_map, :error)

    send_event(state, "run.tool_result", %{
      run_id: state.run_id,
      tool_use_id: id,
      content: result_map,
      is_error: is_error
    })

    %{
      role: "tool",
      tool_call_id: id,
      content: Jason.encode!(result_map)
    }
  end

  defp dispatch_agent("claude-code", payload, state) do
    case ClaudeCode.start(payload["prompt"], model: payload["model"]) do
      {:ok, port} -> {:ok, {{:port, port}, state}}
      {:error, _} = err -> err
    end
  end

  defp dispatch_agent("deepinfra", payload, state) do
    project_dir = payload["project_dir"]
    model = payload["model"]

    user_msg = %{role: "user", content: build_user_content(payload)}

    # Conversation resumption: when both workspace_id + conversation_id
    # are present and we have prior messages stored, continue that
    # thread by appending the new user turn to the prior history. The
    # system prompt + skill body lived at the head of those prior
    # messages, so we don't re-prepend anything.
    #
    # Falling back to a fresh [system, user] when no priors exist —
    # exactly the Phase B behavior — keeps the no-conversation_id path
    # (and runs whose first turn this is) unchanged.
    initial_messages =
      case load_prior_messages(state) do
        {:ok, prior} when prior != [] ->
          prior ++ [user_msg]

        _ ->
          system = compose_system_prompt(payload)

          case system do
            s when is_binary(s) and s != "" -> [%{role: "system", content: s}, user_msg]
            _ -> [user_msg]
          end
      end

    state2 = %{
      state
      | model: model,
        messages: initial_messages,
        project_dir: project_dir,
        tool_iterations: 0
    }

    case start_deepinfra_turn(state2) do
      {:ok, task_pid} -> {:ok, {{:task, task_pid}, state2}}
      {:error, _} = err -> err
    end
  end

  defp dispatch_agent(other, _payload, _state), do: {:error, {:unknown_agent, other}}

  # Plain string for text-only chat; OpenAI-style multimodal array when
  # images are attached. Mirrors `DeepInfra.build_content/2` (now
  # private in the agent) — duplicated here so the runserver can build
  # the user message once and reuse it across tool-loop turns.
  defp build_user_content(payload) do
    case payload["images"] || [] do
      [] ->
        payload["prompt"]

      images ->
        text_part = %{type: "text", text: payload["prompt"]}

        image_parts =
          Enum.flat_map(images, fn
            %{"url" => url} when is_binary(url) and url != "" ->
              [%{type: "image_url", image_url: %{url: url}}]

            %{"base64" => b64, "mime" => mime} when is_binary(b64) and is_binary(mime) ->
              [%{type: "image_url", image_url: %{url: "data:#{mime};base64,#{b64}"}}]

            %{"base64" => b64} when is_binary(b64) ->
              [%{type: "image_url", image_url: %{url: "data:image/png;base64,#{b64}"}}]

            _ ->
              []
          end)

        [text_part | image_parts]
    end
  end

  # Kick off one DeepInfra turn with the current message history. Tools
  # are advertised only when the run has a project_dir (Phase B's
  # sandbox needs somewhere to write); without it, the model gets a
  # plain chat completion (Phase A behavior).
  defp start_deepinfra_turn(%State{project_dir: project_dir, model: model, messages: messages}) do
    tools =
      if is_binary(project_dir) and project_dir != "" do
        Tools.definitions()
      else
        []
      end

    DeepInfra.start_turn(self(),
      messages: messages,
      model: model,
      tools: tools
    )
  end

  # Pull the named skill + design system off the loaders (already running
  # under the application supervisor) and compose them into one system
  # message. Returns nil when neither is set; DeepInfra.start then sends
  # a no-system request unchanged.
  #
  # We extract the body/name strings here (in Runs, which is allowed to
  # depend on Skills and DesignSystems) and hand plain strings to
  # PromptComposer (in Agents, which is not).
  defp compose_system_prompt(payload) do
    {skill_name, skill_body} = lookup_skill_strings(payload["skill_id"])

    {design_system_title, design_system_body} =
      lookup_design_system_strings(payload["design_system_id"])

    PromptComposer.build(%{
      skill_name: skill_name,
      skill_body: skill_body,
      design_system_title: design_system_title,
      design_system_body: design_system_body
    })
  end

  defp lookup_skill_strings(id) when is_binary(id) and id != "" do
    case Skills.Loader.get(id) do
      {:ok, skill} -> {skill.name, skill.body}
      _ -> {nil, nil}
    end
  end

  defp lookup_skill_strings(_), do: {nil, nil}

  defp lookup_design_system_strings(id) when is_binary(id) and id != "" do
    case DesignSystems.Loader.get(id) do
      {:ok, ds} -> {ds.title, ds.body}
      _ -> {nil, nil}
    end
  end

  defp lookup_design_system_strings(_), do: {nil, nil}

  # Conversation-resumption hooks. Both no-ops when this run isn't
  # tagged with a conversation_id; behavior change is gated on the
  # full {workspace_id, conversation_id} pair being present.

  defp load_prior_messages(%State{
         workspace_id: ws,
         conversation_id: conv
       })
       when is_binary(ws) and is_binary(conv) do
    case Conversations.Store.get(ws, conv) do
      {:ok, %{messages: msgs}} when is_list(msgs) -> {:ok, msgs}
      _ -> :none
    end
  end

  defp load_prior_messages(_), do: :none

  defp persist_messages(%State{
         workspace_id: ws,
         conversation_id: conv,
         messages: msgs
       })
       when is_binary(ws) and is_binary(conv) and is_list(msgs) do
    Conversations.Store.put_messages(ws, conv, cap_history(msgs))
    :ok
  end

  defp persist_messages(_), do: :ok

  # Sliding-window cap. Returns msgs unchanged when under the cap;
  # otherwise keeps the head (load-bearing system prompt + skill body)
  # plus the most recent (cap - 1) entries.
  defp cap_history(msgs) when is_list(msgs) do
    if length(msgs) <= @max_persisted_messages do
      msgs
    else
      [head | _] = msgs
      tail_count = @max_persisted_messages - 1
      [head | Enum.take(msgs, -tail_count)]
    end
  end

  defp handle_complete_line(line, state) do
    case ClaudeCode.parse_line(line) do
      :skip ->
        state

      {:status, info} ->
        send_event(state, "run.output", %{
          run_id: state.run_id,
          kind: "status",
          delta: "[#{info.phase}] model=#{info.model || "?"}\n"
        })

        state

      {:text, text} ->
        send_event(state, "run.output", %{
          run_id: state.run_id,
          kind: "agent",
          delta: text
        })

        state

      {:meta, _} ->
        state

      {:result, result} ->
        kind = if result.success, do: "succeeded", else: "failed"

        terminal_payload =
          %{
            run_id: state.run_id,
            status: kind,
            exit: if(result.success, do: 0, else: 1),
            duration_ms: result.duration_ms,
            cost_usd: result.cost_usd,
            ended_at: System.system_time(:millisecond)
          }
          |> maybe_put(:error, result.error)

        send_event(state, "run.terminal", terminal_payload)
        %{state | terminal?: true}
    end
  end

  defp send_event(%State{subscriber: subscriber}, event, payload) when is_pid(subscriber) do
    if Process.alive?(subscriber) do
      send(subscriber, {:run_event, event, payload})
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
