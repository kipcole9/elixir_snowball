defmodule Snowball.Grouping do
  @moduledoc """
  Compile-time helpers for building Snowball grouping bit-tables.

  A grouping in canonical Snowball is a set of codepoints. Generated
  code emits these as compact bit-tables for O(1) membership testing.
  This module produces the `{min_codepoint, bits, max_codepoint}`
  tuple consumed by `Snowball.Runtime.in_grouping/2` and friends.

  Generated stemmer modules call `from_string/1` or `from_codepoints/1`
  inside a module attribute so the table is computed at compile time.
  """

  @doc """
  Build a grouping table from a UTF-8 string whose codepoints are the
  members of the group.

  ### Arguments

  * `string` is a UTF-8 binary listing each member codepoint.

  ### Returns

  * A `{min_cp, bits, max_cp}` tuple suitable for the runtime grouping
    primitives.

  ### Examples

      iex> {97, _bits, 117} = Snowball.Grouping.from_string("aeiou")

  """
  @spec from_string(binary()) :: {integer(), binary(), integer()}
  def from_string(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> from_codepoints()
  end

  @doc """
  Build a grouping table from a list of codepoints.

  ### Arguments

  * `codepoints` is a list of integers.

  ### Returns

  * A `{min_cp, bits, max_cp}` tuple.

  ### Examples

      iex> {97, _bits, 99} = Snowball.Grouping.from_codepoints([?a, ?b, ?c])

  """
  @spec from_codepoints([integer()]) :: {integer(), binary(), integer()}
  def from_codepoints([]), do: {0, <<>>, 0}

  def from_codepoints(codepoints) when is_list(codepoints) do
    min_cp = Enum.min(codepoints)
    max_cp = Enum.max(codepoints)
    span = max_cp - min_cp + 1
    n_bytes = div(span + 7, 8)

    bytes = :erlang.list_to_tuple(List.duplicate(0, n_bytes))

    bits =
      Enum.reduce(codepoints, bytes, fn cp, acc ->
        offset = cp - min_cp
        byte_index = div(offset, 8)
        bit_index = rem(offset, 8)
        current = elem(acc, byte_index)
        :erlang.setelement(byte_index + 1, acc, Bitwise.bor(current, Bitwise.bsl(1, bit_index)))
      end)

    bits_binary =
      bits
      |> Tuple.to_list()
      |> :erlang.list_to_binary()

    {min_cp, bits_binary, max_cp}
  end
end
