defmodule BeamDesign.Conversations.Store do
  @moduledoc """
  ETS-backed store for per-conversation state.

  Key: `{workspace_id :: String.t(), conversation_id :: String.t()}`.
  Value: `%ConversationState{}`.

  Concurrent reads are lock-free (ETS `:set` with `read_concurrency:
  true`). Writes serialize through this GenServer so two RunServers
  finishing turns at the same time don't shred each other's
  state. RunServers are usually one-per-conversation in practice
  (the React UI gates one in-flight run per thread), so contention
  is negligible.

  v1 lifetime is the daemon process. Durable persistence — journal
  the table to disk so daemon restart doesn't reset every thread —
  is a follow-up.
  """
  use GenServer

  @table :beam_design_conversations

  defmodule ConversationState do
    @moduledoc false
    @enforce_keys [:workspace_id, :conversation_id]
    defstruct [
      :workspace_id,
      :conversation_id,
      messages: [],
      agent_session_ids: %{},
      updated_at: 0
    ]

    @type t :: %__MODULE__{
            workspace_id: String.t(),
            conversation_id: String.t(),
            messages: [map()],
            agent_session_ids: %{optional(String.t()) => String.t()},
            updated_at: integer()
          }
  end

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.merge([name: __MODULE__], opts))
  end

  @doc """
  Look up the conversation. Returns `{:ok, state}` or `:not_found`.
  Lock-free read off ETS — safe to call from any RunServer process.
  """
  @spec get(String.t(), String.t()) :: {:ok, ConversationState.t()} | :not_found
  def get(workspace_id, conversation_id)
      when is_binary(workspace_id) and is_binary(conversation_id) do
    case :ets.lookup(@table, {workspace_id, conversation_id}) do
      [{_, state}] -> {:ok, state}
      [] -> :not_found
    end
  end

  def get(_, _), do: :not_found

  @doc """
  Replace the message list for the conversation, creating the entry
  if it doesn't exist yet. Idempotent.
  """
  @spec put_messages(String.t(), String.t(), [map()]) :: :ok
  def put_messages(workspace_id, conversation_id, messages)
      when is_binary(workspace_id) and is_binary(conversation_id) and is_list(messages) do
    GenServer.call(__MODULE__, {:put_messages, workspace_id, conversation_id, messages})
  end

  @doc """
  Record an agent's opaque session id for this conversation. Future
  Claude Code resumption hook — Phase 4A doesn't write this yet.
  `agent` is the registry id (`"claude-code"`, `"deepinfra"`).
  """
  @spec put_agent_session_id(String.t(), String.t(), String.t(), String.t()) :: :ok
  def put_agent_session_id(workspace_id, conversation_id, agent, session_id)
      when is_binary(workspace_id) and is_binary(conversation_id) and
             is_binary(agent) and is_binary(session_id) do
    GenServer.call(
      __MODULE__,
      {:put_agent_session_id, workspace_id, conversation_id, agent, session_id}
    )
  end

  @doc """
  Forget the conversation. Used by tests and by an explicit user "new
  thread" action when we wire one up.
  """
  @spec clear(String.t(), String.t()) :: :ok
  def clear(workspace_id, conversation_id)
      when is_binary(workspace_id) and is_binary(conversation_id) do
    GenServer.call(__MODULE__, {:clear, workspace_id, conversation_id})
  end

  @doc "Number of conversations currently held. For telemetry."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size) || 0

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(:ok) do
    table =
      :ets.new(@table, [
        :set,
        :named_table,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put_messages, ws, conv, messages}, _from, state) do
    now = System.system_time(:millisecond)

    record =
      case :ets.lookup(@table, {ws, conv}) do
        [{_, existing}] ->
          %{existing | messages: messages, updated_at: now}

        [] ->
          %ConversationState{
            workspace_id: ws,
            conversation_id: conv,
            messages: messages,
            updated_at: now
          }
      end

    :ets.insert(@table, {{ws, conv}, record})
    {:reply, :ok, state}
  end

  def handle_call({:put_agent_session_id, ws, conv, agent, sid}, _from, state) do
    now = System.system_time(:millisecond)

    record =
      case :ets.lookup(@table, {ws, conv}) do
        [{_, existing}] ->
          %{
            existing
            | agent_session_ids: Map.put(existing.agent_session_ids, agent, sid),
              updated_at: now
          }

        [] ->
          %ConversationState{
            workspace_id: ws,
            conversation_id: conv,
            agent_session_ids: %{agent => sid},
            updated_at: now
          }
      end

    :ets.insert(@table, {{ws, conv}, record})
    {:reply, :ok, state}
  end

  def handle_call({:clear, ws, conv}, _from, state) do
    :ets.delete(@table, {ws, conv})
    {:reply, :ok, state}
  end
end
