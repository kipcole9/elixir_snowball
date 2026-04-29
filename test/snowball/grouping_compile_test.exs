defmodule Snowball.GroupingCompileTest do
  use ExUnit.Case, async: true
  doctest Snowball.Grouping

  alias Snowball.Runtime
  alias Snowball.Grouping

  test "from_string roundtrips through Runtime.in_grouping" do
    vowels = Grouping.from_string("aeiouy")

    state = Runtime.new("apple")
    assert %Runtime{cursor: 1} = Runtime.in_grouping(state, vowels)

    state = %{Runtime.new("byte") | cursor: 0}
    assert :fail = Runtime.in_grouping(state, vowels)
  end

  test "from_string handles non-contiguous ranges" do
    # English Y-found case: caps Y mixed with lowercase vowels
    g = Grouping.from_string("aeiouyY")

    cap_y_state = Runtime.new("Yes")
    assert %Runtime{cursor: 1} = Runtime.in_grouping(cap_y_state, g)
  end

  test "from_string handles multibyte codepoints" do
    g = Grouping.from_string("äöü")

    state = Runtime.new("öl")
    # 'ö' is 2 bytes in UTF-8
    assert %Runtime{cursor: 2} = Runtime.in_grouping(state, g)
  end
end
