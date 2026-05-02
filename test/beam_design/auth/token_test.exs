defmodule BeamDesign.Auth.TokenTest do
  use ExUnit.Case, async: false

  alias BeamDesign.Auth.Token

  describe "mint/0" do
    test "returns a 64-char lowercase hex string (256 bits)" do
      token = Token.mint()
      assert is_binary(token)
      assert String.length(token) == 64
      assert token =~ ~r/^[0-9a-f]+$/
    end

    test "returns a different token each call" do
      refute Token.mint() == Token.mint()
    end
  end

  describe "write/2" do
    test "creates the file with mode 0600" do
      path = tmp_token_path()
      token = Token.mint()

      assert :ok = Token.write(path, token)
      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert {:ok, ^token} = File.read(path)
    end

    test "creates the parent directory with mode 0700 if absent" do
      base = Path.join(System.tmp_dir!(), "beam_design_test_#{System.unique_integer([:positive])}")
      path = Path.join(base, "auth-token")
      assert :ok = Token.write(path, Token.mint())
      assert {:ok, %File.Stat{mode: mode}} = File.stat(base)
      assert Bitwise.band(mode, 0o777) == 0o700
    end

    test "overwrites an existing token (no append)" do
      path = tmp_token_path()
      old = Token.mint()
      new = Token.mint()
      assert :ok = Token.write(path, old)
      assert :ok = Token.write(path, new)
      assert {:ok, ^new} = File.read(path)
    end
  end

  describe "verify/2" do
    test "true for matching tokens" do
      t = Token.mint()
      assert Token.verify(t, t)
    end

    test "false for mismatching same-length tokens" do
      refute Token.verify(Token.mint(), Token.mint())
    end

    test "false for differing-length tokens" do
      refute Token.verify("short", Token.mint())
    end

    test "false for non-binary inputs" do
      refute Token.verify(nil, "x")
      refute Token.verify("x", nil)
    end
  end

  defp tmp_token_path do
    Path.join(
      System.tmp_dir!(),
      "beam_design_test_token_#{System.unique_integer([:positive])}"
    )
  end
end
