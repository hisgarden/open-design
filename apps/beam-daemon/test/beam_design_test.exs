defmodule BeamDesignTest do
  use ExUnit.Case

  test "BeamDesign module loads as the top-level namespace" do
    assert Code.ensure_loaded?(BeamDesign)
  end
end
