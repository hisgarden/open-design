defmodule BeamDesign.Conversations.StoreTest do
  # NOT async — the store is a named singleton; ETS table is shared.
  use ExUnit.Case, async: false

  alias BeamDesign.Conversations.Store
  alias BeamDesign.Conversations.Store.ConversationState

  setup do
    # Clear all entries between tests to avoid bleed-through. Use the
    # public API rather than reaching into ETS so this exercises the
    # same code path the real callers do.
    on_exit(fn ->
      :ets.tab2list(:beam_design_conversations)
      |> Enum.each(fn {{ws, conv}, _} -> Store.clear(ws, conv) end)
    end)

    :ok
  end

  test "get/2 returns :not_found for an unknown conversation" do
    assert Store.get("ws-a", "missing-conv") == :not_found
  end

  test "put_messages/3 then get/2 round-trips the message list" do
    assert :ok = Store.put_messages("ws-a", "conv-1", [%{role: "user", content: "hi"}])
    assert {:ok, %ConversationState{} = state} = Store.get("ws-a", "conv-1")
    assert state.messages == [%{role: "user", content: "hi"}]
    assert state.workspace_id == "ws-a"
    assert state.conversation_id == "conv-1"
    assert state.updated_at > 0
  end

  test "put_messages/3 replaces (not appends) on second call" do
    Store.put_messages("ws-a", "conv-2", [%{role: "user", content: "first"}])
    Store.put_messages("ws-a", "conv-2", [%{role: "user", content: "second"}])
    assert {:ok, state} = Store.get("ws-a", "conv-2")
    assert state.messages == [%{role: "user", content: "second"}]
  end

  test "different workspaces with the same conversation_id stay isolated" do
    Store.put_messages("ws-a", "conv-shared", [%{role: "user", content: "from-a"}])
    Store.put_messages("ws-b", "conv-shared", [%{role: "user", content: "from-b"}])

    assert {:ok, state_a} = Store.get("ws-a", "conv-shared")
    assert state_a.messages == [%{role: "user", content: "from-a"}]

    assert {:ok, state_b} = Store.get("ws-b", "conv-shared")
    assert state_b.messages == [%{role: "user", content: "from-b"}]
  end

  test "clear/2 forgets the conversation" do
    Store.put_messages("ws-a", "conv-3", [%{role: "user", content: "x"}])
    assert {:ok, _} = Store.get("ws-a", "conv-3")

    assert :ok = Store.clear("ws-a", "conv-3")
    assert Store.get("ws-a", "conv-3") == :not_found
  end

  test "clear/2 on a missing conversation is a no-op" do
    assert :ok = Store.clear("ws-a", "ghost-conv")
  end

  test "put_agent_session_id/4 records the id without touching messages" do
    Store.put_messages("ws-a", "conv-4", [%{role: "user", content: "hi"}])
    Store.put_agent_session_id("ws-a", "conv-4", "claude-code", "sess_abc123")

    assert {:ok, state} = Store.get("ws-a", "conv-4")
    assert state.agent_session_ids["claude-code"] == "sess_abc123"
    assert state.messages == [%{role: "user", content: "hi"}]
  end

  test "put_agent_session_id/4 creates the entry when missing" do
    Store.put_agent_session_id("ws-a", "conv-5", "claude-code", "sess_xyz")
    assert {:ok, state} = Store.get("ws-a", "conv-5")
    assert state.messages == []
    assert state.agent_session_ids == %{"claude-code" => "sess_xyz"}
  end

  test "non-binary keys return :not_found and don't crash" do
    assert Store.get(nil, "conv") == :not_found
    assert Store.get("ws", nil) == :not_found
    assert Store.get(123, "conv") == :not_found
  end

  test "count/0 reflects current entries" do
    base = Store.count()
    Store.put_messages("ws-a", "conv-count-1", [%{}])
    Store.put_messages("ws-a", "conv-count-2", [%{}])
    assert Store.count() == base + 2
  end
end
