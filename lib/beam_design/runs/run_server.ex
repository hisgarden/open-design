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

  alias BeamDesign.Agents.{ClaudeCode, DeepInfra}

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
      :terminal?
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
      terminal?: false
    }

    case dispatch_agent(agent, payload) do
      {:ok, owner_ref} ->
        send_event(state, "run.started", %{
          run_id: run_id,
          agent: agent,
          model: payload["model"],
          started_at: state.started_at
        })

        {:ok, %{state | port: owner_ref}}

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

  # DeepInfra streaming events: text chunks then terminal {:agent_done, ...}.
  def handle_info({:agent_chunk, text}, state) when is_binary(text) do
    send_event(state, "run.output", %{run_id: state.run_id, kind: "agent", delta: text})
    {:noreply, state}
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

  defp dispatch_agent("claude-code", payload) do
    case ClaudeCode.start(payload["prompt"], model: payload["model"]) do
      {:ok, port} -> {:ok, {:port, port}}
      {:error, _} = err -> err
    end
  end

  defp dispatch_agent("deepinfra", payload) do
    case DeepInfra.start(self(), payload["prompt"],
           model: payload["model"],
           images: payload["images"] || []
         ) do
      {:ok, task_pid} -> {:ok, {:task, task_pid}}
      {:error, _} = err -> err
    end
  end

  defp dispatch_agent(other, _payload), do: {:error, {:unknown_agent, other}}

  @impl true
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
