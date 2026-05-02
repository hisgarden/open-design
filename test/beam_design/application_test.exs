defmodule BeamDesign.ApplicationTest do
  use ExUnit.Case

  describe "supervision tree" do
    test "all named subsystem supervisors are alive" do
      for name <- [
            BeamDesign.Workspace.Supervisor,
            BeamDesign.DesignSystems.Supervisor,
            BeamDesign.Skills.Supervisor,
            BeamDesign.Journal.Supervisor,
            BeamDesign.Runs.Supervisor
          ] do
        pid = Process.whereis(name)
        assert is_pid(pid), "expected #{inspect(name)} to be alive"
        assert Process.alive?(pid)
      end
    end

    test "killing one subsystem supervisor doesn't take down siblings" do
      ws_pid_before = Process.whereis(BeamDesign.Workspace.Supervisor)
      ds_pid = Process.whereis(BeamDesign.DesignSystems.Supervisor)
      runs_pid = Process.whereis(BeamDesign.Runs.Supervisor)

      ref = Process.monitor(ws_pid_before)
      Process.exit(ws_pid_before, :kill)
      assert_receive {:DOWN, ^ref, :process, ^ws_pid_before, :killed}, 1_000

      # Wait briefly for the top supervisor to restart Workspace.Supervisor.
      Process.sleep(100)

      ws_pid_after = Process.whereis(BeamDesign.Workspace.Supervisor)
      assert is_pid(ws_pid_after)
      assert ws_pid_after != ws_pid_before
      assert Process.alive?(ds_pid)
      assert Process.alive?(runs_pid)
    end
  end
end
