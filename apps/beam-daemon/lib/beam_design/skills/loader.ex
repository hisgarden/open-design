defmodule BeamDesign.Skills.Loader do
  @moduledoc """
  GenServer + ETS store + file-watcher for skills under the workspace's
  `skills/` directory.

  Mirrors `BeamDesign.DesignSystems.Loader` — see that module for the
  shared design rationale (debounced file-watch, broadcast on change).
  """
  use GenServer

  alias BeamDesign.Skills.Parser
  alias BeamDesign.Workspace.Config

  @table :beam_skills
  @debounce_ms 250
  @pubsub_topic "skills"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec list() :: [Parser.Skill.t()]
  def list do
    case :ets.whereis(@table) do
      :undefined -> []
      tid -> :ets.tab2list(tid) |> Enum.map(fn {_id, sk} -> sk end) |> Enum.sort_by(& &1.id)
    end
  end

  @spec get(String.t()) :: {:ok, Parser.Skill.t()} | :error
  def get(id) when is_binary(id) do
    case :ets.whereis(@table) do
      :undefined ->
        :error

      tid ->
        case :ets.lookup(tid, id) do
          [{^id, sk}] -> {:ok, sk}
          [] -> :error
        end
    end
  end

  @spec count() :: non_neg_integer()
  def count, do: list() |> length()

  @spec topic() :: String.t()
  def topic, do: @pubsub_topic

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    dir = Config.skills_dir()
    load_all(dir)

    case start_watcher(dir) do
      {:ok, watcher} ->
        FileSystem.subscribe(watcher)
        {:ok, %{dir: dir, watcher: watcher, debounce: nil}}

      {:error, reason} ->
        require Logger
        Logger.warning("[skills] file_system failed (#{inspect(reason)}); no hot-reload")
        {:ok, %{dir: dir, watcher: nil, debounce: nil}}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, _event}, %{watcher: watcher} = state) do
    if state.debounce, do: Process.cancel_timer(state.debounce)
    timer = Process.send_after(self(), :reload, @debounce_ms)
    {:noreply, %{state | debounce: timer}}
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    {:noreply, state}
  end

  def handle_info(:reload, state) do
    before_ids = :ets.tab2list(@table) |> Enum.map(fn {id, _} -> id end) |> MapSet.new()
    :ets.delete_all_objects(@table)
    load_all(state.dir)
    after_ids = :ets.tab2list(@table) |> Enum.map(fn {id, _} -> id end) |> MapSet.new()

    Phoenix.PubSub.broadcast(
      BeamDesign.PubSub,
      @pubsub_topic,
      {:skills_changed,
       %{
         added: MapSet.difference(after_ids, before_ids) |> MapSet.to_list(),
         removed: MapSet.difference(before_ids, after_ids) |> MapSet.to_list(),
         total: MapSet.size(after_ids)
       }}
    )

    {:noreply, %{state | debounce: nil}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp load_all(dir) do
    if File.dir?(dir) do
      dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        path = Path.join([dir, entry, "SKILL.md"])

        case Parser.parse_file(path) do
          {:ok, sk} -> :ets.insert(@table, {sk.id, sk})
          _ -> :ok
        end
      end)
    end
  end

  defp start_watcher(dir) do
    if File.dir?(dir) do
      FileSystem.start_link(dirs: [dir], name: nil)
    else
      {:error, :no_dir}
    end
  end
end
