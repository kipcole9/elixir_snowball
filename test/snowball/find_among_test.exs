defmodule Snowball.FindAmongTest do
  use ExUnit.Case, async: true

  alias Snowball.Runtime

  describe "find_among/2" do
    # Sorted entries; substring_i = -1 (no prefix chain).
    @basic [
      {"abc", -1, 1, nil},
      {"abd", -1, 2, nil},
      {"xyz", -1, 3, nil}
    ]

    test "matches first entry" do
      state = Runtime.new("abcdef")
      assert {%Runtime{cursor: 3}, 1} = Runtime.find_among(state, @basic)
    end

    test "matches second entry by binary search" do
      state = Runtime.new("abdef")
      assert {%Runtime{cursor: 3}, 2} = Runtime.find_among(state, @basic)
    end

    test "matches last entry" do
      state = Runtime.new("xyz!")
      assert {%Runtime{cursor: 3}, 3} = Runtime.find_among(state, @basic)
    end

    test "fails when no entry matches" do
      state = Runtime.new("zzz")
      assert :fail = Runtime.find_among(state, @basic)
    end

    test "fails when match would cross limit" do
      state = Runtime.new("ab")
      assert :fail = Runtime.find_among(state, @basic)
    end
  end

  describe "find_among/2 with substring_i prefix chain" do
    # Entries sorted; "abc" is prefix of "abcd" — substring_i links
    # "abcd" -> 0 (the "abc" entry).
    @prefix_chain [
      {"abc", -1, 1, nil},
      {"abcd", 0, 2, nil}
    ]

    test "matches longer entry first" do
      state = Runtime.new("abcdef")
      assert {%Runtime{cursor: 4}, 2} = Runtime.find_among(state, @prefix_chain)
    end

    test "falls back to shorter prefix when longer does not match" do
      state = Runtime.new("abcXY")
      assert {%Runtime{cursor: 3}, 1} = Runtime.find_among(state, @prefix_chain)
    end
  end

  describe "find_among/2 with filter functions" do
    test "filter that succeeds returns the result" do
      entries = [
        {"abc", -1, 42, fn state -> state end}
      ]

      state = Runtime.new("abcdef")
      assert {%Runtime{cursor: 3}, 42} = Runtime.find_among(state, entries)
    end

    test "filter that fails falls through to substring_i" do
      entries = [
        {"ab", -1, 1, nil},
        {"abc", 0, 2, fn _ -> :fail end}
      ]

      state = Runtime.new("abcdef")
      assert {%Runtime{cursor: 2}, 1} = Runtime.find_among(state, entries)
    end

    test "filter fails with no fallback returns :fail" do
      entries = [
        {"abc", -1, 2, fn _ -> :fail end}
      ]

      state = Runtime.new("abcdef")
      assert :fail = Runtime.find_among(state, entries)
    end
  end

  describe "find_among_b/2" do
    @suffixes [
      # Sorted lexically. Backward scan looks for these suffixes ending
      # at the cursor.
      {"ed", -1, 1, nil},
      {"ing", -1, 2, nil},
      {"s", -1, 3, nil}
    ]

    test "matches a backward suffix" do
      state = %{Runtime.new("running") | cursor: 7}
      assert {%Runtime{cursor: 4}, 2} = Runtime.find_among_b(state, @suffixes)
    end

    test "matches a different backward suffix" do
      state = %{Runtime.new("walked") | cursor: 6}
      assert {%Runtime{cursor: 4}, 1} = Runtime.find_among_b(state, @suffixes)
    end

    test "fails when no suffix matches" do
      state = %{Runtime.new("zzz") | cursor: 3}
      assert :fail = Runtime.find_among_b(state, @suffixes)
    end
  end

  describe "find_among_b/2 with substring_i prefix chain" do
    # Sorted: "ee" < "eed". "eed" extends "ee".
    @ee_chain [
      {"ee", -1, 1, nil},
      {"eed", 0, 2, nil}
    ]

    test "matches the longer suffix first" do
      state = %{Runtime.new("greed") | cursor: 5}
      assert {%Runtime{cursor: 2}, 2} = Runtime.find_among_b(state, @ee_chain)
    end

    test "falls back to shorter via substring_i" do
      state = %{Runtime.new("agree") | cursor: 5}
      assert {%Runtime{cursor: 3}, 1} = Runtime.find_among_b(state, @ee_chain)
    end
  end
end
