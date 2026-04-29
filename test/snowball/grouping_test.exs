defmodule Snowball.GroupingTest do
  use ExUnit.Case, async: true

  alias Snowball.Runtime

  # Vowels grouping {a,e,i,o,u} = codepoints 97,101,105,111,117
  # min=97 max=117, bits over 21 codepoints (3 bytes):
  #   bit 0  (97  - 97 = 0)  : a -> byte 0 bit 0 -> 0x01
  #   bit 4  (101 - 97 = 4)  : e -> byte 0 bit 4 -> 0x10
  #   bit 8  (105 - 97 = 8)  : i -> byte 1 bit 0 -> 0x01
  #   bit 14 (111 - 97 = 14) : o -> byte 1 bit 6 -> 0x40
  #   bit 20 (117 - 97 = 20) : u -> byte 2 bit 4 -> 0x10
  @vowels {97, <<0x11, 0x41, 0x10>>, 117}

  describe "in_grouping/2" do
    test "matches and advances on vowel" do
      state = Runtime.new("apple")
      assert %Runtime{cursor: 1} = Runtime.in_grouping(state, @vowels)
    end

    test "fails on non-vowel" do
      state = %{Runtime.new("apple") | cursor: 1}
      assert :fail = Runtime.in_grouping(state, @vowels)
    end

    test "fails at limit" do
      state = %{Runtime.new("a") | cursor: 1}
      assert :fail = Runtime.in_grouping(state, @vowels)
    end
  end

  describe "out_grouping/2" do
    test "matches and advances on consonant" do
      state = %{Runtime.new("apple") | cursor: 1}
      assert %Runtime{cursor: 2} = Runtime.out_grouping(state, @vowels)
    end

    test "fails on vowel" do
      state = Runtime.new("apple")
      assert :fail = Runtime.out_grouping(state, @vowels)
    end
  end

  describe "in_grouping_b/2" do
    test "matches the codepoint before the cursor" do
      state = %{Runtime.new("apple") | cursor: 5}
      assert %Runtime{cursor: 4} = Runtime.in_grouping_b(state, @vowels)
    end

    test "fails when char before cursor is not in grouping" do
      state = %{Runtime.new("apple") | cursor: 4}
      assert :fail = Runtime.in_grouping_b(state, @vowels)
    end
  end

  describe "go_in_grouping/2" do
    test "scans forward through grouping members and stops at non-member" do
      state = Runtime.new("aeiou_xyz")
      assert %Runtime{cursor: 5} = Runtime.go_in_grouping(state, @vowels)
    end

    test "fails when entire remainder is in the grouping" do
      state = Runtime.new("aeiou")
      assert :fail = Runtime.go_in_grouping(state, @vowels)
    end
  end

  describe "go_out_grouping/2" do
    test "scans forward through non-members until grouping member" do
      state = Runtime.new("xyzabc_e")
      # First vowel is 'a' at offset 3
      assert %Runtime{cursor: 3} = Runtime.go_out_grouping(state, @vowels)
    end

    test "fails when no grouping member found before limit" do
      state = Runtime.new("xyz")
      assert :fail = Runtime.go_out_grouping(state, @vowels)
    end
  end

  describe "multibyte UTF-8" do
    # German: ä = 228, ö = 246, ü = 252
    # min=228 max=252 -> 25 codepoints, 4 bytes of bits.
    #   228 - 228 = 0  -> byte 0 bit 0  -> 0x01
    #   246 - 228 = 18 -> byte 2 bit 2  -> 0x04
    #   252 - 228 = 24 -> byte 3 bit 0  -> 0x01
    @umlauts {228, <<0x01, 0x00, 0x04, 0x01>>, 252}

    test "in_grouping with multibyte codepoint advances by codepoint byte size" do
      state = Runtime.new("ä-test")
      # 'ä' is 2 bytes in UTF-8
      assert %Runtime{cursor: 2} = Runtime.in_grouping(state, @umlauts)
    end

    test "in_grouping_b retreats by codepoint byte size" do
      state = %{Runtime.new("xü") | cursor: 3}
      # 'ü' is 2 bytes in UTF-8
      assert %Runtime{cursor: 1} = Runtime.in_grouping_b(state, @umlauts)
    end
  end
end
