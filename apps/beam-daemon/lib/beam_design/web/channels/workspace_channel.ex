defmodule BeamDesign.Web.WorkspaceChannel do
  @moduledoc """
  The workspace channel — single load-bearing protocol surface between the
  daemon and its clients. Topic shape: `design:v1:<workspace_id>`.

  As of U7-claude-code, `run.start` spawns a real `BeamDesign.Runs.RunServer`
  that wraps the local Claude Code CLI (`claude -p ...`) via OTP Port and
  streams its parsed stream-json events back as `run.output` events. A
  `BEAM_DESIGN_SYNTHETIC_RUNS=1` env var keeps the original synthetic
  stream available for protocol testing without spending agent credits.
  """
  use Phoenix.Channel

  alias BeamDesign.DesignSystems
  alias BeamDesign.Protocol.Version
  alias BeamDesign.Runs
  alias BeamDesign.Skills
  alias BeamDesign.Workspace.Config

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
    Phoenix.PubSub.subscribe(BeamDesign.PubSub, DesignSystems.Loader.topic())
    Phoenix.PubSub.subscribe(BeamDesign.PubSub, Skills.Loader.topic())

    push(socket, "welcome", %{
      protocol_version: Version.current(),
      workspace_id: workspace_id,
      capabilities: [
        "run.start",
        "run.cancel",
        "spec.write",
        "design_systems.list",
        "design_systems.get",
        "skills.list",
        "skills.get"
      ],
      agents: BeamDesign.Agents.Registry.list(),
      design_systems_count: DesignSystems.Loader.count(),
      skills_count: Skills.Loader.count(),
      workspace_dir: Config.workspace_dir(),
      daemon_id: BeamDesign.Auth.DaemonId.current(),
      synthetic_runs: synthetic_runs?()
    })

    {:noreply, socket}
  end

  def handle_info({:design_systems_changed, payload}, socket) do
    push(socket, "design_systems.changed", payload)
    {:noreply, socket}
  end

  def handle_info({:skills_changed, payload}, socket) do
    push(socket, "skills.changed", payload)
    {:noreply, socket}
  end

  def handle_info({:emit_run_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  def handle_info({:run_event, event, payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("run.start", payload, socket) do
    case validate_run_start(payload) do
      :ok ->
        run_id = "run_" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))

        if synthetic_runs?() do
          schedule_synthetic_run(run_id, payload)

          {:reply,
           {:ok,
            %{
              run_id: run_id,
              status: "started",
              stub_mode: true,
              note: "synthetic run (BEAM_DESIGN_SYNTHETIC_RUNS=1)"
            }}, socket}
        else
          agent = Map.get(payload, "agent", "claude-code")

          # Inject the channel-authenticated workspace_id into payload
          # so RunServer doesn't have to (and shouldn't) trust the
          # bridge to declare which workspace a run belongs to.
          enriched_payload = Map.put(payload, "workspace_id", socket.assigns.workspace_id)

          case Runs.Supervisor.start_run(%{
                 run_id: run_id,
                 subscriber: self(),
                 agent: agent,
                 payload: enriched_payload
               }) do
            {:ok, _pid} ->
              {:reply, {:ok, %{run_id: run_id, status: "started", agent: agent, stub_mode: false}},
               socket}

            {:error, reason} ->
              {:reply, {:error, %{reason: "run_start_failed", details: inspect(reason)}}, socket}
          end
        end

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

  def handle_in("design_systems.list", _payload, socket) do
    items =
      DesignSystems.Loader.list()
      |> Enum.map(&design_system_summary/1)

    {:reply, {:ok, %{items: items, total: length(items)}}, socket}
  end

  def handle_in("design_systems.get", %{"id" => id}, socket) do
    case DesignSystems.Loader.get(id) do
      {:ok, ds} -> {:reply, {:ok, design_system_full(ds)}, socket}
      :error -> {:reply, {:error, %{reason: "not_found", id: id}}, socket}
    end
  end

  def handle_in("skills.list", _payload, socket) do
    items =
      Skills.Loader.list()
      |> Enum.map(&skill_summary/1)

    {:reply, {:ok, %{items: items, total: length(items)}}, socket}
  end

  def handle_in("skills.get", %{"id" => id}, socket) do
    case Skills.Loader.get(id) do
      {:ok, sk} -> {:reply, {:ok, skill_full(sk)}, socket}
      :error -> {:reply, {:error, %{reason: "not_found", id: id}}, socket}
    end
  end

  def handle_in(unknown, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event", event: unknown}}, socket}
  end

  defp design_system_summary(ds) do
    %{id: ds.id, title: ds.title, category: ds.category, description: ds.description}
  end

  defp design_system_full(ds) do
    Map.put(design_system_summary(ds), :body, ds.body)
  end

  defp skill_summary(sk) do
    %{id: sk.id, name: sk.name, description: sk.description, triggers: sk.triggers}
  end

  defp skill_full(sk) do
    Map.put(skill_summary(sk), :body, sk.body)
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

  defp synthetic_runs?, do: System.get_env("BEAM_DESIGN_SYNTHETIC_RUNS") == "1"
end
