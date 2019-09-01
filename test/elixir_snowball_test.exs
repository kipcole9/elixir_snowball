defmodule ElixirSnowballTest do
  use ExUnit.Case
  doctest ElixirSnowball

  test "greets the world" do
    assert ElixirSnowball.hello() == :world
  end
end
