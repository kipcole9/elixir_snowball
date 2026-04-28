defmodule Snowball.GroupingCompileTest do
  use ExUnit.Case, async: true
  doctest Snowball.Grouping

  alias Snowball.Stemmer
  alias Snowball.Grouping

  test "from_string roundtrips through Stemmer.in_grouping" do
    vowels = Grouping.from_string("aeiouy")

    state = Stemmer.new("apple")
    assert %Stemmer{cursor: 1} = Stemmer.in_grouping(state, vowels)

    state = %{Stemmer.new("byte") | cursor: 0}
    assert :fail = Stemmer.in_grouping(state, vowels)
  end

  test "from_string handles non-contiguous ranges" do
    # English Y-found case: caps Y mixed with lowercase vowels
    g = Grouping.from_string("aeiouyY")

    cap_y_state = Stemmer.new("Yes")
    assert %Stemmer{cursor: 1} = Stemmer.in_grouping(cap_y_state, g)
  end

  test "from_string handles multibyte codepoints" do
    g = Grouping.from_string("äöü")

    state = Stemmer.new("öl")
    # 'ö' is 2 bytes in UTF-8
    assert %Stemmer{cursor: 2} = Stemmer.in_grouping(state, g)
  end
end
