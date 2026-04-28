defmodule Snowball.FindAmongTest do
  use ExUnit.Case, async: true

  alias Snowball.Stemmer

  describe "find_among/2" do
    # Sorted entries; substring_i = -1 (no prefix chain).
    @basic [
      {"abc", -1, 1, nil},
      {"abd", -1, 2, nil},
      {"xyz", -1, 3, nil}
    ]

    test "matches first entry" do
      state = Stemmer.new("abcdef")
      assert {%Stemmer{cursor: 3}, 1} = Stemmer.find_among(state, @basic)
    end

    test "matches second entry by binary search" do
      state = Stemmer.new("abdef")
      assert {%Stemmer{cursor: 3}, 2} = Stemmer.find_among(state, @basic)
    end

    test "matches last entry" do
      state = Stemmer.new("xyz!")
      assert {%Stemmer{cursor: 3}, 3} = Stemmer.find_among(state, @basic)
    end

    test "fails when no entry matches" do
      state = Stemmer.new("zzz")
      assert :fail = Stemmer.find_among(state, @basic)
    end

    test "fails when match would cross limit" do
      state = Stemmer.new("ab")
      assert :fail = Stemmer.find_among(state, @basic)
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
      state = Stemmer.new("abcdef")
      assert {%Stemmer{cursor: 4}, 2} = Stemmer.find_among(state, @prefix_chain)
    end

    test "falls back to shorter prefix when longer does not match" do
      state = Stemmer.new("abcXY")
      assert {%Stemmer{cursor: 3}, 1} = Stemmer.find_among(state, @prefix_chain)
    end
  end

  describe "find_among/2 with filter functions" do
    test "filter that succeeds returns the result" do
      entries = [
        {"abc", -1, 42, fn state -> state end}
      ]

      state = Stemmer.new("abcdef")
      assert {%Stemmer{cursor: 3}, 42} = Stemmer.find_among(state, entries)
    end

    test "filter that fails falls through to substring_i" do
      entries = [
        {"ab", -1, 1, nil},
        {"abc", 0, 2, fn _ -> :fail end}
      ]

      state = Stemmer.new("abcdef")
      assert {%Stemmer{cursor: 2}, 1} = Stemmer.find_among(state, entries)
    end

    test "filter fails with no fallback returns :fail" do
      entries = [
        {"abc", -1, 2, fn _ -> :fail end}
      ]

      state = Stemmer.new("abcdef")
      assert :fail = Stemmer.find_among(state, entries)
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
      state = %{Stemmer.new("running") | cursor: 7}
      assert {%Stemmer{cursor: 4}, 2} = Stemmer.find_among_b(state, @suffixes)
    end

    test "matches a different backward suffix" do
      state = %{Stemmer.new("walked") | cursor: 6}
      assert {%Stemmer{cursor: 4}, 1} = Stemmer.find_among_b(state, @suffixes)
    end

    test "fails when no suffix matches" do
      state = %{Stemmer.new("zzz") | cursor: 3}
      assert :fail = Stemmer.find_among_b(state, @suffixes)
    end
  end

  describe "find_among_b/2 with substring_i prefix chain" do
    # Sorted: "ee" < "eed". "eed" extends "ee".
    @ee_chain [
      {"ee", -1, 1, nil},
      {"eed", 0, 2, nil}
    ]

    test "matches the longer suffix first" do
      state = %{Stemmer.new("greed") | cursor: 5}
      assert {%Stemmer{cursor: 2}, 2} = Stemmer.find_among_b(state, @ee_chain)
    end

    test "falls back to shorter via substring_i" do
      state = %{Stemmer.new("agree") | cursor: 5}
      assert {%Stemmer{cursor: 3}, 1} = Stemmer.find_among_b(state, @ee_chain)
    end
  end
end
