defmodule BeamDesign.Web.WorkspaceChannelTest do
  use ExUnit.Case, async: false

  import Phoenix.ChannelTest

  alias BeamDesign.Web.{UserSocket, WorkspaceChannel}

  @endpoint BeamDesign.Web.Endpoint

  setup do
    {:ok, socket} = connect(UserSocket, %{"token" => BeamDesign.Auth.Holder.current()}, %{})
    {:ok, socket: socket}
  end

  describe "join" do
    test "v1 topic with valid workspace_id succeeds and pushes welcome", %{socket: socket} do
      {:ok, _reply, _channel} = subscribe_and_join(socket, WorkspaceChannel, "design:v1:my-ws")

      assert_push(
        "welcome",
        %{
          protocol_version: 1,
          workspace_id: "my-ws",
          capabilities: caps,
          synthetic_runs: true
        },
        2_000
      )

      assert "run.start" in caps
    end

    test "v0 topic is rejected with version mismatch error", %{socket: socket} do
      assert {:error, %{reason: "protocol_version_mismatch", server_version: 1, client_version: 0}} =
               subscribe_and_join(socket, WorkspaceChannel, "design:v0:my-ws")
    end

    test "malformed topic is rejected with invalid_topic error", %{socket: socket} do
      assert {:error, %{reason: "invalid_topic"}} =
               subscribe_and_join(socket, WorkspaceChannel, "design:vX:my-ws")
    end
  end

  describe "run.start (synthetic)" do
    setup %{socket: socket} do
      {:ok, _reply, channel} = subscribe_and_join(socket, WorkspaceChannel, "design:v1:my-ws")
      assert_push("welcome", _, 500)
      {:ok, channel: channel}
    end

    test "valid payload returns started reply and emits the synthetic stream", %{
      channel: channel
    } do
      ref =
        push(channel, "run.start", %{
          "skill_id" => "html-ppt",
          "design_system_id" => "obsidian-claude-gradient",
          "prompt" => "make a 5-slide deck"
        })

      assert_reply(ref, :ok, %{run_id: run_id, status: "started", stub_mode: true}, 2_000)

      assert_push("run.started", %{run_id: ^run_id, started_at: _}, 1_000)
      assert_push("run.output", %{run_id: ^run_id, kind: "stdout", delta: d1}, 1_000)
      assert d1 =~ "Synthetic run for skill=html-ppt"
      assert_push("run.output", %{run_id: ^run_id, delta: d2}, 1_000)
      assert d2 =~ "Prompt: make a 5-slide deck"
      assert_push("run.terminal", %{run_id: ^run_id, status: "succeeded", exit: 0}, 1_000)
    end

    test "missing required fields returns invalid_payload error", %{channel: channel} do
      ref = push(channel, "run.start", %{"skill_id" => "html-ppt"})

      assert_reply(
        ref,
        :error,
        %{reason: "invalid_payload", missing: missing},
        500
      )

      assert "design_system_id" in missing
      assert "prompt" in missing
    end

    test "unknown event returns unknown_event error", %{channel: channel} do
      ref = push(channel, "run.bogus", %{})
      assert_reply(ref, :error, %{reason: "unknown_event", event: "run.bogus"}, 500)
    end
  end

  describe "auth" do
    test "connect with wrong token is refused" do
      assert :error = connect(UserSocket, %{"token" => "definitely-not-the-token"}, %{})
    end

    test "connect with no token is refused" do
      assert :error = connect(UserSocket, %{}, %{})
    end
  end
end
