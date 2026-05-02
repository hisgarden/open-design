defmodule BeamDesign.Web.WorkspaceChannel do
  @moduledoc """
  The workspace channel — single load-bearing protocol surface between the
  daemon and its clients. Topic shape: `design:v1:<workspace_id>`.

  v1 stub handlers are end-to-end real over the wire (join, welcome push,
  run.start → synthetic streaming response, error envelopes for unknown
  events) but the run handler does not yet spawn an agent CLI. Real agent
  orchestration arrives in U7; until then a synthetic 3-event stream lets
  clients verify the protocol works.
  """
  use Phoenix.Channel

  alias BeamDesign.Protocol.Version

  @impl true
  def join("design:v" <> _ = topic, _payload, socket) do
    case parse_topic(topic) do
      {:ok, version, workspace_id} when version == 1 ->
        send(self(), {:after_join, workspace_id})
        {:ok, assign(socket, :workspace_id, workspace_id)}

      {:ok, version, _workspace_id} ->
        {:error,
         %{
           reason: "protocol_version_mismatch",
           server_version: Version.current(),
           client_version: version
         }}

      :error ->
        {:error, %{reason: "invalid_topic", expected: "#{Version.topic_prefix()}:<workspace_id>"}}
    end
  end

  def join(_topic, _payload, _socket),
    do: {:error, %{reason: "invalid_topic", expected: "#{Version.topic_prefix()}:<workspace_id>"}}

  @impl true
  def handle_info({:after_join, workspace_id}, socket) do
    push(socket, "welcome", %{
      protocol_version: Version.current(),
      workspace_id: workspace_id,
      capabilities: ["run.start", "run.cancel", "spec.write"],
      stub_mode: true
    })

    {:noreply, socket}
  end

  def handle_info({:emit_run_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("run.start", payload, socket) do
    case validate_run_start(payload) do
      :ok ->
        run_id = "run_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
        schedule_synthetic_run(run_id, payload)

        {:reply,
         {:ok,
          %{
            run_id: run_id,
            status: "started",
            stub_mode: true,
            note: "synthetic run; real agent CLI orchestration arrives in U7"
          }}, socket}

      {:error, missing} ->
        {:reply, {:error, %{reason: "invalid_payload", missing: missing}}, socket}
    end
  end

  def handle_in("run.cancel", %{"run_id" => _run_id}, socket) do
    {:reply, {:error, %{reason: "not_yet_implemented", unit: "U7"}}, socket}
  end

  def handle_in("spec.write", _payload, socket) do
    {:reply, {:error, %{reason: "not_yet_implemented", unit: "U8"}}, socket}
  end

  def handle_in(unknown, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event", event: unknown}}, socket}
  end

  defp parse_topic(topic) do
    case String.split(topic, ":") do
      ["design", "v" <> version_str, workspace_id] when workspace_id != "" ->
        case Integer.parse(version_str) do
          {v, ""} -> {:ok, v, workspace_id}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp validate_run_start(payload) do
    required = ["skill_id", "design_system_id", "prompt"]
    missing = Enum.reject(required, &Map.has_key?(payload, &1))
    if missing == [], do: :ok, else: {:error, missing}
  end

  defp schedule_synthetic_run(run_id, payload) do
    base = %{run_id: run_id}
    me = self()

    spawn(fn ->
      Process.sleep(50)
      send(me, {:emit_run_event, "run.started", Map.put(base, :started_at, now_ms())})

      Process.sleep(100)

      send(
        me,
        {:emit_run_event, "run.output",
         Map.merge(base, %{
           kind: "stdout",
           delta:
             "Synthetic run for skill=#{payload["skill_id"]} ds=#{payload["design_system_id"]}\n"
         })}
      )

      Process.sleep(100)

      send(
        me,
        {:emit_run_event, "run.output",
         Map.merge(base, %{
           kind: "stdout",
           delta: "Prompt: #{payload["prompt"]}\n"
         })}
      )

      Process.sleep(100)

      send(
        me,
        {:emit_run_event, "run.terminal",
         Map.merge(base, %{status: "succeeded", exit: 0, ended_at: now_ms()})}
      )
    end)

    :ok
  end

  defp now_ms, do: System.system_time(:millisecond)
end
