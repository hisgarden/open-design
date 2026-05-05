defmodule BeamDesign.Auth.DaemonIdTest do
  # NOT async — module uses :persistent_term + env vars (process-global).
  use ExUnit.Case, async: false

  alias BeamDesign.Auth.DaemonId

  setup do
    dir = Path.join(System.tmp_dir!(), "beam-daemon-id-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "daemon.id")

    System.put_env("BEAM_DESIGN_DAEMON_ID_PATH", path)
    # Clear any cached id from a prior test (or from the app boot
    # sequence in this same process). Don't call reload! here — that
    # would eagerly mint the id, which would defeat the
    # "first call mints" assertion.
    :persistent_term.erase(BeamDesign.Auth.DaemonId)

    on_exit(fn ->
      File.rm_rf!(dir)
      System.delete_env("BEAM_DESIGN_DAEMON_ID_PATH")
      :persistent_term.erase(BeamDesign.Auth.DaemonId)
    end)

    {:ok, path: path}
  end

  test "current/0 mints a UUID on first call when no file exists", %{path: path} do
    refute File.exists?(path)
    id = DaemonId.current()
    assert is_binary(id)
    assert String.match?(id, ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    assert File.exists?(path)
    assert String.trim(File.read!(path)) == id
  end

  test "minted file is mode 0600", %{path: path} do
    DaemonId.current()
    %File.Stat{mode: mode} = File.stat!(path)
    # Lower 9 bits are the unix permission bits.
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "current/0 is idempotent across reload!", %{path: _} do
    id1 = DaemonId.current()
    id2 = DaemonId.reload!()
    assert id1 == id2
  end

  test "current/0 reads an existing valid uuid file", %{path: path} do
    seeded = "550e8400-e29b-41d4-a716-446655440000"
    File.write!(path, seeded <> "\n")
    File.chmod!(path, 0o600)
    DaemonId.reload!()
    assert DaemonId.current() == seeded
  end

  test "current/0 regenerates when file is corrupt", %{path: path} do
    File.write!(path, "not-a-uuid")
    DaemonId.reload!()
    id = DaemonId.current()
    assert id != "not-a-uuid"
    assert String.match?(id, ~r/^[0-9a-f]{8}-/)
  end

  test "minted UUID has v4 version + RFC 4122 variant bits", %{path: _} do
    id = DaemonId.current()
    # Position [14] is the version nibble; [19] is the variant nibble.
    assert String.at(id, 14) == "4"
    variant = String.at(id, 19)
    assert variant in ["8", "9", "a", "b"]
  end
end
