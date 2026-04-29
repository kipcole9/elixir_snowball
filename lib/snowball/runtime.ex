defmodule Snowball.Runtime do
  @moduledoc """
  Runtime state and primitive operations for Snowball stemmers.

  This is the Elixir analogue of the canonical `BaseStemmer` class found in
  the Python and JavaScript snowball runtimes. Generated stemmer modules
  call into the functions on this module to manipulate cursor position,
  test character groupings, dispatch to suffix tables (`among`), and
  perform slice replacements.

  ## State model

  Snowball is conceptually mutable — every command moves the cursor or
  rewrites the buffer. In Elixir we thread an immutable `%Runtime{}`
  through every primitive. Each primitive returns either the updated
  struct (success) or the atom `:fail` (failure). Generated code uses
  pattern matches like:

      case Runtime.eq_s(state, "ing") do
        :fail -> :fail
        state -> state
      end

  to compose primitives.

  ## Cursor units

  All cursor positions and limits are **byte offsets** into the UTF-8
  buffer. This matches the canonical `-utf8` mode of the Snowball
  reference compiler and lets `eq_s/2` perform a direct byte-level
  prefix match (UTF-8 is self-synchronising, so byte positions land on
  codepoint boundaries provided cursor moves are made via the public
  primitives).

  ## State fields

  * `current` — the working buffer (UTF-8 binary).

  * `cursor` — the current scan position (byte offset).

  * `limit` — the forward limit (byte offset, exclusive).

  * `limit_backward` — the backward limit (byte offset, inclusive lower
    bound).

  * `bra` and `ket` — the slice marks set by the `[` and `]` Snowball
    commands. Replacement and deletion operate on the `[bra, ket)`
    range.

  """

  defstruct current: "",
            cursor: 0,
            limit: 0,
            limit_backward: 0,
            bra: 0,
            ket: 0,
            vars: %{}

  @type t :: %__MODULE__{
          current: binary(),
          cursor: non_neg_integer(),
          limit: non_neg_integer(),
          limit_backward: non_neg_integer(),
          bra: non_neg_integer(),
          ket: non_neg_integer(),
          vars: %{optional(atom()) => term()}
        }

  @typedoc """
  A failure return from a primitive. Generated code propagates `:fail`
  upward until a `try`, `or` or similar combinator catches it.
  """
  @type fail :: :fail

  @typedoc "The result of a Snowball primitive that may succeed or fail."
  @type result :: t() | fail()

  @doc """
  Create a new stemmer state for the given input word.

  ### Arguments

  * `word` is the input word as a UTF-8 binary.

  ### Returns

  * A `t:t/0` initialised with `cursor` at the start, `limit` at the end,
    `limit_backward` at the start, and `bra` / `ket` at cursor / limit
    respectively (matching `BaseStemmer.set_current` in canonical
    Snowball).

  ### Examples

      iex> Snowball.Runtime.new("running")
      %Snowball.Runtime{current: "running", cursor: 0, limit: 7, limit_backward: 0, bra: 0, ket: 7, vars: %{}}

  """
  @spec new(binary()) :: t()
  def new(word) when is_binary(word) do
    size = byte_size(word)

    %__MODULE__{
      current: word,
      cursor: 0,
      limit: size,
      limit_backward: 0,
      bra: 0,
      ket: size
    }
  end

  @doc """
  Return the buffer contents up to the current `limit`.

  This is the canonical `assign_to` operation — used as the final
  result extractor at the end of a stem.

  ### Arguments

  * `state` is a `t:t/0`.

  ### Returns

  * A UTF-8 binary containing the buffer from byte 0 up to `limit`.

  ### Examples

      iex> "hello" |> Snowball.Runtime.new() |> Snowball.Runtime.assign_to()
      "hello"

  """
  @spec assign_to(t()) :: binary()
  def assign_to(%__MODULE__{current: current, limit: limit}) do
    binary_part(current, 0, limit)
  end

  @doc """
  Return the slice between `bra` and `ket`.

  ### Arguments

  * `state` is a `t:t/0`.

  ### Returns

  * A UTF-8 binary containing the bytes from `bra` (inclusive) to `ket`
    (exclusive).

  ### Examples

      iex> state = Snowball.Runtime.new("abcdef")
      iex> state = %{state | bra: 1, ket: 4}
      iex> Snowball.Runtime.slice_to(state)
      "bcd"

  """
  @spec slice_to(t()) :: binary()
  def slice_to(%__MODULE__{current: current, bra: bra, ket: ket})
      when bra >= 0 and bra <= ket do
    binary_part(current, bra, ket - bra)
  end

  # ----------------------------------------------------------------------
  # Equality primitives — `eq_s` and its backward variant.
  # ----------------------------------------------------------------------

  @doc """
  Test whether the buffer at the cursor begins with `string`; on success
  advance the cursor past the match.

  Mirrors `eq_s` in the canonical runtime. `string` is matched as raw
  UTF-8 bytes — this is sound because Snowball literals are always
  whole codepoint sequences.

  ### Arguments

  * `state` is a `t:t/0`.

  * `string` is a UTF-8 binary to match at the cursor.

  ### Returns

  * The updated state with cursor advanced by `byte_size(string)` on
    match.

  * `:fail` if the buffer at the cursor does not start with `string`,
    or if the match would cross the forward `limit`.

  ### Examples

      iex> state = Snowball.Runtime.new("running")
      iex> %Snowball.Runtime{cursor: 3} = Snowball.Runtime.eq_s(state, "run")
      iex> Snowball.Runtime.eq_s(state, "xyz")
      :fail

  """
  @spec eq_s(t(), binary()) :: result()
  def eq_s(%__MODULE__{current: current, cursor: cursor, limit: limit} = state, string)
      when is_binary(string) do
    size = byte_size(string)

    if cursor + size > limit do
      :fail
    else
      case current do
        <<_::binary-size(^cursor), ^string::binary-size(^size), _::binary>> ->
          %{state | cursor: cursor + size}

        _ ->
          :fail
      end
    end
  end

  @doc """
  Test whether the buffer immediately before the cursor ends with
  `string`; on success retreat the cursor by `byte_size(string)`.

  Mirrors `eq_s_b` in the canonical runtime — used inside `backwards`
  blocks where the scan moves right-to-left.

  ### Arguments

  * `state` is a `t:t/0`.

  * `string` is a UTF-8 binary to match ending at the cursor.

  ### Returns

  * The updated state with cursor retreated by `byte_size(string)` on
    match.

  * `:fail` if the bytes before the cursor do not equal `string`, or
    if the match would cross `limit_backward`.

  ### Examples

      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | cursor: 7}
      iex> %Snowball.Runtime{cursor: 4} = Snowball.Runtime.eq_s_b(state, "ing")
      iex> Snowball.Runtime.eq_s_b(state, "xyz")
      :fail

  """
  @spec eq_s_b(t(), binary()) :: result()
  def eq_s_b(
        %__MODULE__{current: current, cursor: cursor, limit_backward: lb} = state,
        string
      )
      when is_binary(string) do
    size = byte_size(string)

    if cursor - size < lb do
      :fail
    else
      start = cursor - size

      case current do
        <<_::binary-size(^start), ^string::binary-size(^size), _::binary>> ->
          %{state | cursor: start}

        _ ->
          :fail
      end
    end
  end

  # ----------------------------------------------------------------------
  # Grouping primitives.
  #
  # Groupings in canonical Snowball are bit-tables indexed by codepoint;
  # each grouping provides:
  #
  #   * `min_codepoint` — the minimum codepoint in the group.
  #   * `bits` — a tuple/binary of bytes; bit (cp - min) >> 3 / (cp - min) & 7
  #     indicates membership.
  #
  # Code generators emit the bit-table at the top of each module. We
  # accept the bit-table as a function argument so the generator can
  # inline it as a module attribute.
  # ----------------------------------------------------------------------

  @doc """
  Test whether the codepoint at the cursor is a member of `grouping`;
  on success, advance the cursor past that codepoint.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_codepoint, bits, max_codepoint}` tuple where
    `bits` is a binary bit-table indexed by `codepoint - min_codepoint`.

  ### Returns

  * The state with cursor advanced past the codepoint on a successful
    match.

  * `:fail` if the cursor is at the limit, or if the codepoint at the
    cursor is outside the grouping range or has its bit unset.

  ### Examples

      iex> # Grouping {97, <<0b00000101>>, 100} = {a,c} (bits 0,2 set: 97,99)
      iex> grouping = {97, <<0b00000101>>, 100}
      iex> state = Snowball.Runtime.new("abc")
      iex> %Snowball.Runtime{cursor: 1} = Snowball.Runtime.in_grouping(state, grouping)
      iex> Snowball.Runtime.in_grouping(%{state | cursor: 1}, grouping)
      :fail

  """
  @spec in_grouping(t(), {integer(), binary(), integer()}) :: result()
  def in_grouping(%__MODULE__{cursor: cursor, limit: limit} = state, grouping)
      when cursor < limit do
    case codepoint_at(state.current, cursor, limit) do
      {cp, size} ->
        if member?(grouping, cp) do
          %{state | cursor: cursor + size}
        else
          :fail
        end

      :error ->
        :fail
    end
  end

  def in_grouping(%__MODULE__{}, _grouping), do: :fail

  @doc """
  Test whether the codepoint at the cursor is **not** a member of
  `grouping`; on success, advance the cursor past that codepoint.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_codepoint, bits, max_codepoint}` tuple.

  ### Returns

  * The state with cursor advanced past the codepoint on a successful
    non-match.

  * `:fail` at limit or when the codepoint is in the grouping.

  ### Examples

      iex> grouping = {97, <<0b00010101>>, 101}
      iex> state = Snowball.Runtime.new("bace")
      iex> %Snowball.Runtime{cursor: 1} = Snowball.Runtime.out_grouping(state, grouping)

  """
  @spec out_grouping(t(), {integer(), binary(), integer()}) :: result()
  def out_grouping(%__MODULE__{cursor: cursor, limit: limit} = state, grouping)
      when cursor < limit do
    case codepoint_at(state.current, cursor, limit) do
      {cp, size} ->
        if member?(grouping, cp) do
          :fail
        else
          %{state | cursor: cursor + size}
        end

      :error ->
        :fail
    end
  end

  def out_grouping(%__MODULE__{}, _grouping), do: :fail

  @doc """
  Backward variant of `in_grouping/2`: test the codepoint immediately
  before the cursor; on success retreat past it.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The updated state with cursor retreated by the codepoint's byte size.

  * `:fail` if the codepoint is not in the grouping, or the cursor is at
    `limit_backward`.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | cursor: 2, limit_backward: 0}
      iex> match?(%Snowball.Runtime{cursor: 1}, Snowball.Runtime.in_grouping_b(state, g))
      true
      iex> state2 = %{state | cursor: 7}
      iex> Snowball.Runtime.in_grouping_b(state2, g)
      :fail

  """
  @spec in_grouping_b(t(), {integer(), binary(), integer()}) :: result()
  def in_grouping_b(
        %__MODULE__{cursor: cursor, limit_backward: lb} = state,
        grouping
      )
      when cursor > lb do
    case codepoint_before(state.current, cursor, lb) do
      {cp, size} ->
        if member?(grouping, cp) do
          %{state | cursor: cursor - size}
        else
          :fail
        end

      :error ->
        :fail
    end
  end

  def in_grouping_b(%__MODULE__{}, _grouping), do: :fail

  @doc """
  Backward variant of `out_grouping/2`: test the codepoint immediately
  before the cursor; on success retreat past it.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The updated state with cursor retreated by the codepoint's byte size.

  * `:fail` if the codepoint is in the grouping, or the cursor is at
    `limit_backward`.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | cursor: 7, limit_backward: 0}
      iex> match?(%Snowball.Runtime{cursor: 6}, Snowball.Runtime.out_grouping_b(state, g))
      true
      iex> state2 = %{state | cursor: 2}
      iex> Snowball.Runtime.out_grouping_b(state2, g)
      :fail

  """
  @spec out_grouping_b(t(), {integer(), binary(), integer()}) :: result()
  def out_grouping_b(
        %__MODULE__{cursor: cursor, limit_backward: lb} = state,
        grouping
      )
      when cursor > lb do
    case codepoint_before(state.current, cursor, lb) do
      {cp, size} ->
        if member?(grouping, cp) do
          :fail
        else
          %{state | cursor: cursor - size}
        end

      :error ->
        :fail
    end
  end

  def out_grouping_b(%__MODULE__{}, _grouping), do: :fail

  @doc """
  Scan forward while the codepoint at the cursor is in `grouping`.

  Used for `goto`-style commands that consume a run of grouping
  members. Mirrors `go_in_grouping` in the canonical runtime.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The state with cursor advanced past the run, when at least one
    non-member codepoint is found before the limit.

  * `:fail` if the entire remainder up to limit is in the grouping.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("aeibc")
      iex> match?(%Snowball.Runtime{cursor: 3}, Snowball.Runtime.go_in_grouping(state, g))
      true

  """
  @spec go_in_grouping(t(), {integer(), binary(), integer()}) :: result()
  def go_in_grouping(%__MODULE__{} = state, grouping) do
    do_go_in_grouping(state, grouping)
  end

  defp do_go_in_grouping(%__MODULE__{cursor: cursor, limit: limit}, _grouping)
       when cursor >= limit,
       do: :fail

  defp do_go_in_grouping(%__MODULE__{cursor: cursor, limit: limit} = state, grouping) do
    case codepoint_at(state.current, cursor, limit) do
      {cp, size} ->
        if member?(grouping, cp) do
          do_go_in_grouping(%{state | cursor: cursor + size}, grouping)
        else
          state
        end

      :error ->
        :fail
    end
  end

  @doc """
  Scan forward while the codepoint at the cursor is **not** in
  `grouping`.

  Mirrors `go_out_grouping` in the canonical runtime — finds the next
  grouping member.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The state with cursor pointing at a grouping member, when one is
    found before the limit.

  * `:fail` if no grouping member is found up to the limit.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("bce")
      iex> match?(%Snowball.Runtime{cursor: 2}, Snowball.Runtime.go_out_grouping(state, g))
      true

  """
  @spec go_out_grouping(t(), {integer(), binary(), integer()}) :: result()
  def go_out_grouping(%__MODULE__{} = state, grouping) do
    do_go_out_grouping(state, grouping)
  end

  defp do_go_out_grouping(%__MODULE__{cursor: cursor, limit: limit}, _grouping)
       when cursor >= limit,
       do: :fail

  defp do_go_out_grouping(%__MODULE__{cursor: cursor, limit: limit} = state, grouping) do
    case codepoint_at(state.current, cursor, limit) do
      {cp, size} ->
        if member?(grouping, cp) do
          state
        else
          do_go_out_grouping(%{state | cursor: cursor + size}, grouping)
        end

      :error ->
        :fail
    end
  end

  @doc """
  Backward variant of `go_in_grouping/2`: scan backward while the
  codepoint before the cursor is in `grouping`.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The state with cursor retreated past the run, when at least one
    non-member codepoint is found at or above `limit_backward`.

  * `:fail` if all codepoints back to `limit_backward` are in the grouping.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("bcaei")
      iex> state = %{state | cursor: 5, limit_backward: 0}
      iex> match?(%Snowball.Runtime{cursor: 2}, Snowball.Runtime.go_in_grouping_b(state, g))
      true

  """
  @spec go_in_grouping_b(t(), {integer(), binary(), integer()}) :: result()
  def go_in_grouping_b(%__MODULE__{} = state, grouping) do
    do_go_in_grouping_b(state, grouping)
  end

  defp do_go_in_grouping_b(%__MODULE__{cursor: cursor, limit_backward: lb}, _grouping)
       when cursor <= lb,
       do: :fail

  defp do_go_in_grouping_b(
         %__MODULE__{cursor: cursor, limit_backward: lb} = state,
         grouping
       ) do
    case codepoint_before(state.current, cursor, lb) do
      {cp, size} ->
        if member?(grouping, cp) do
          do_go_in_grouping_b(%{state | cursor: cursor - size}, grouping)
        else
          state
        end

      :error ->
        :fail
    end
  end

  @doc """
  Backward variant of `go_out_grouping/2`: scan backward while the
  codepoint before the cursor is **not** in `grouping`.

  ### Arguments

  * `state` is a `t:t/0`.

  * `grouping` is a `{min_cp, bits, max_cp}` table from `Snowball.Grouping`.

  ### Returns

  * The state with cursor retreated to point past a grouping member,
    when one is found at or above `limit_backward`.

  * `:fail` if no grouping member is found.

  ### Examples

      iex> g = Snowball.Grouping.from_string("aeiou")
      iex> state = Snowball.Runtime.new("aeibc")
      iex> state = %{state | cursor: 5, limit_backward: 0}
      iex> match?(%Snowball.Runtime{cursor: 3}, Snowball.Runtime.go_out_grouping_b(state, g))
      true

  """
  @spec go_out_grouping_b(t(), {integer(), binary(), integer()}) :: result()
  def go_out_grouping_b(%__MODULE__{} = state, grouping) do
    do_go_out_grouping_b(state, grouping)
  end

  defp do_go_out_grouping_b(%__MODULE__{cursor: cursor, limit_backward: lb}, _grouping)
       when cursor <= lb,
       do: :fail

  defp do_go_out_grouping_b(
         %__MODULE__{cursor: cursor, limit_backward: lb} = state,
         grouping
       ) do
    case codepoint_before(state.current, cursor, lb) do
      {cp, size} ->
        if member?(grouping, cp) do
          state
        else
          do_go_out_grouping_b(%{state | cursor: cursor - size}, grouping)
        end

      :error ->
        :fail
    end
  end

  # ----------------------------------------------------------------------
  # Internal helpers.
  # ----------------------------------------------------------------------

  # Return `{codepoint, byte_size}` for the codepoint starting at byte
  # offset `cursor`, or `:error` if the bytes are not a valid UTF-8
  # codepoint or the codepoint extends past the limit.
  @doc false
  @spec codepoint_at(binary(), non_neg_integer(), non_neg_integer()) ::
          {integer(), 1..4} | :error
  def codepoint_at(binary, cursor, limit) do
    case binary do
      <<_::binary-size(^cursor), rest::binary>> ->
        case rest do
          <<cp::utf8, _::binary>> ->
            size = utf8_byte_size(cp)
            if cursor + size <= limit, do: {cp, size}, else: :error

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # Return `{codepoint, byte_size}` for the codepoint immediately
  # before byte offset `cursor`, or `:error`.
  @doc false
  @spec codepoint_before(binary(), non_neg_integer(), non_neg_integer()) ::
          {integer(), 1..4} | :error
  def codepoint_before(binary, cursor, limit_backward) do
    # Walk back up to 4 bytes looking for a valid UTF-8 lead byte that
    # produces a codepoint of exactly the right length.
    do_codepoint_before(binary, cursor, limit_backward, 1)
  end

  defp do_codepoint_before(_binary, _cursor, _lb, n) when n > 4, do: :error

  defp do_codepoint_before(binary, cursor, lb, n) do
    start = cursor - n

    if start < lb do
      :error
    else
      case binary do
        <<_::binary-size(^start), cp::utf8, _::binary>> ->
          if utf8_byte_size(cp) == n, do: {cp, n}, else: do_codepoint_before(binary, cursor, lb, n + 1)

        _ ->
          do_codepoint_before(binary, cursor, lb, n + 1)
      end
    end
  end

  defp utf8_byte_size(cp) when cp < 0x80, do: 1
  defp utf8_byte_size(cp) when cp < 0x800, do: 2
  defp utf8_byte_size(cp) when cp < 0x10000, do: 3
  defp utf8_byte_size(_), do: 4

  defp member?({min_cp, bits, max_cp}, cp)
       when is_integer(cp) and cp >= min_cp and cp <= max_cp do
    offset = cp - min_cp
    byte_index = div(offset, 8)
    bit_index = rem(offset, 8)

    case bits do
      <<_::binary-size(^byte_index), byte, _::binary>> ->
        Bitwise.band(byte, Bitwise.bsl(1, bit_index)) != 0

      _ ->
        false
    end
  end

  defp member?({_min_cp, _bits, _max_cp}, _cp), do: false

  # ----------------------------------------------------------------------
  # Scan-and-replace optimisation.
  # ----------------------------------------------------------------------

  @doc false
  @spec scan_and_replace_forward(t(), %{integer() => binary()}) :: t()
  def scan_and_replace_forward(%__MODULE__{} = state, char_map) do
    %{current: current, cursor: cursor, limit: limit} = state
    active_len = limit - cursor
    <<head::binary-size(^cursor), active::binary-size(^active_len), tail::binary>> = current
    new_active = do_scan_replace(active, char_map, [])
    new_limit = cursor + byte_size(new_active)
    %{state | current: head <> new_active <> tail, limit: new_limit, cursor: new_limit}
  end

  defp do_scan_replace(<<>>, _char_map, acc),
    do: IO.iodata_to_binary(:lists.reverse(acc))

  defp do_scan_replace(<<cp::utf8, rest::binary>>, char_map, acc) do
    new_acc =
      case Map.fetch(char_map, cp) do
        {:ok, repl} -> [repl | acc]
        :error -> [<<cp::utf8>> | acc]
      end

    do_scan_replace(rest, char_map, new_acc)
  end

  # ----------------------------------------------------------------------
  # Slice / replacement primitives.
  # ----------------------------------------------------------------------

  @doc """
  Replace the byte range `[c_bra, c_ket)` in the buffer with `string`,
  adjusting `cursor` and `limit` accordingly.

  Mirrors `replace_s` in the canonical runtime. Returns the updated
  state along with the size adjustment (positive if the replacement
  grew the buffer, negative if it shrank).

  ### Arguments

  * `state` is a `t:t/0`.

  * `c_bra` is the inclusive start of the range to replace (byte
    offset).

  * `c_ket` is the exclusive end of the range (byte offset).

  * `string` is the UTF-8 binary replacement.

  ### Returns

  * `{state, adjustment}` where `adjustment` is `byte_size(string) - (c_ket - c_bra)`.

  ### Examples

      iex> state = Snowball.Runtime.new("abcdef")
      iex> {%Snowball.Runtime{current: "abXYZdef", limit: 8}, 2} =
      ...>   Snowball.Runtime.replace_s(state, 2, 3, "XYZ")

  """
  @spec replace_s(t(), non_neg_integer(), non_neg_integer(), binary()) :: {t(), integer()}
  def replace_s(
        %__MODULE__{current: current, cursor: cursor, limit: limit} = state,
        c_bra,
        c_ket,
        string
      )
      when is_integer(c_bra) and is_integer(c_ket) and c_bra >= 0 and c_bra <= c_ket and
             is_binary(string) do
    new_size = byte_size(string)
    adjustment = new_size - (c_ket - c_bra)

    head = binary_part(current, 0, c_bra)
    tail = binary_part(current, c_ket, byte_size(current) - c_ket)
    new_current = head <> string <> tail

    new_cursor =
      cond do
        cursor >= c_ket -> cursor + adjustment
        cursor > c_bra -> c_bra
        true -> cursor
      end

    {%{state | current: new_current, cursor: new_cursor, limit: limit + adjustment}, adjustment}
  end

  @doc """
  Replace the marked slice `[bra, ket)` with `string`.

  Mirrors `slice_from` in the canonical runtime. After replacement,
  `ket` is moved to `bra + byte_size(string)`.

  ### Arguments

  * `state` is a `t:t/0`.

  * `string` is the UTF-8 binary replacement.

  ### Returns

  * The updated state.

  ### Examples

      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | bra: 4, ket: 7}
      iex> %Snowball.Runtime{current: "runneed"} = Snowball.Runtime.slice_from(state, "eed")

  """
  @spec slice_from(t(), binary()) :: t()
  def slice_from(%__MODULE__{bra: bra, ket: ket} = state, string)
      when bra >= 0 and bra <= ket and is_binary(string) do
    {state, _adjustment} = replace_s(state, bra, ket, string)
    %{state | ket: bra + byte_size(string)}
  end

  @doc """
  Delete the marked slice `[bra, ket)`.

  Equivalent to `slice_from(state, "")`. Mirrors `slice_del` in the
  canonical runtime.

  ### Arguments

  * `state` is a `t:t/0`.

  ### Returns

  * The updated state with `[bra, ket)` removed.

  ### Examples

      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | bra: 3, ket: 7}
      iex> %Snowball.Runtime{current: "run", limit: 3} = Snowball.Runtime.slice_del(state)

  """
  @spec slice_del(t()) :: t()
  def slice_del(%__MODULE__{} = state), do: slice_from(state, "")

  @doc """
  Count the number of Unicode codepoints in a UTF-8 binary.

  Snowball's `len` builtin counts codepoints, not grapheme clusters.
  Elixir's `String.length/1` counts grapheme clusters, which differs for
  scripts that combine base characters with combining marks (Tamil,
  Hindi, Arabic, etc.). This function correctly counts codepoints by
  counting lead bytes and single-byte characters in the UTF-8 encoding.

  ### Arguments

  * `string` is a UTF-8 binary.

  ### Returns

  * The number of Unicode codepoints in `string`.

  ### Examples

      iex> Snowball.Runtime.codepoint_length("hello")
      5

      iex> Snowball.Runtime.codepoint_length("ஞ்சா")
      4

  """
  @spec codepoint_length(binary()) :: non_neg_integer()
  def codepoint_length(string) when is_binary(string) do
    # UTF-8 continuation bytes are in range 0x80..0xBF (0b10xxxxxx).
    # All other bytes are either single-byte codepoints (0x00..0x7F) or
    # lead bytes for multi-byte sequences (0xC0..0xFF). Counting
    # non-continuation bytes gives the codepoint count.
    count_codepoints(string, 0)
  end

  defp count_codepoints(<<>>, acc), do: acc

  defp count_codepoints(<<byte, rest::binary>>, acc) do
    if Bitwise.band(byte, 0xC0) == 0x80 do
      count_codepoints(rest, acc)
    else
      count_codepoints(rest, acc + 1)
    end
  end

  @doc """
  Insert `string` at byte range `[c_bra, c_ket)`, adjusting `bra` and
  `ket` if they fall after `c_bra`.

  Mirrors `insert_s` / `insert` in the canonical runtime. Used by
  `insert` and `attach` Snowball commands.

  ### Arguments

  * `state` is a `t:t/0`.

  * `c_bra` is the inclusive start of the range (byte offset).

  * `c_ket` is the exclusive end of the range (byte offset).

  * `string` is the UTF-8 binary to insert.

  ### Returns

  * The updated state.

  ### Examples

      iex> state = Snowball.Runtime.new("abcdef")
      iex> %Snowball.Runtime{current: "abXYZdef"} = Snowball.Runtime.insert(state, 2, 3, "XYZ")

  """
  @spec insert(t(), non_neg_integer(), non_neg_integer(), binary()) :: t()
  def insert(%__MODULE__{bra: bra, ket: ket} = state, c_bra, c_ket, string) do
    {state, adjustment} = replace_s(state, c_bra, c_ket, string)

    new_bra = if c_bra <= bra, do: bra + adjustment, else: bra
    new_ket = if c_bra <= ket, do: ket + adjustment, else: ket

    %{state | bra: new_bra, ket: new_ket}
  end

  # ----------------------------------------------------------------------
  # Among dispatcher — binary search on a sorted list of suffix entries.
  # ----------------------------------------------------------------------
  #
  # An among entry is a tuple:
  #
  #   {string, substring_i, result, function}
  #
  # where:
  #
  #   * `string` — the literal to match (UTF-8 binary).
  #   * `substring_i` — index of the longest entry that is a prefix of
  #     this one, or -1 if none. Used to chain failed sub-matches in
  #     the second-loop fallback.
  #   * `result` — the integer returned to the caller on a successful
  #     match (typically a 1-based case selector in generated code).
  #   * `function` — `nil`, or a `(state -> result())` function that
  #     filters this entry. If present and it returns `:fail`, fall
  #     through to `substring_i`.
  #
  # The algorithm mirrors `find_among` / `find_among_b` in
  # `BaseStemmer` (Python: basestemmer.py:102-212).

  @typedoc """
  An entry in an among table:

  `{string, substring_i, result, function_or_nil}`

  * `string` — the literal to match (UTF-8 binary).
  * `substring_i` — index in the entries list of the longest entry
    that is a prefix of this one, or `-1` if none.
  * `result` — non-zero integer returned on a successful match.
  * `function_or_nil` — optional filter function `(t() -> t() | :fail)`.
  """
  @type among_entry ::
          {binary(), integer(), integer(), nil | (t() -> result())}

  @doc """
  Forward `among (...)` dispatcher. Performs a binary search over
  `entries` looking for the longest match at the cursor; on success,
  advances the cursor past the match and returns `{state, result}`
  where `result` is the matched entry's `result` value.

  ### Arguments

  * `state` is a `t:t/0`.

  * `entries` is a list of `t:among_entry/0` tuples, sorted
    lexicographically by `string`.

  ### Returns

  * `{updated_state, result}` on a successful match (advance cursor).

  * `:fail` if no entry matches, or if a matched entry's filter
    function fails and there is no `substring_i` fallback.

  ### Examples

      iex> entries = [{"ing", -1, 1, nil}, {"ly", -1, 2, nil}]
      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | cursor: 4}
      iex> {%Snowball.Runtime{cursor: 7}, 1} = Snowball.Runtime.find_among(state, entries)

  """
  @spec find_among(t(), [among_entry()]) :: {t(), integer()} | fail()
  def find_among(%__MODULE__{cursor: cursor, limit: limit} = state, entries)
      when is_list(entries) and entries != [] do
    vec = List.to_tuple(entries)
    n = tuple_size(vec)
    do_find_among(state, vec, n, cursor, limit)
  end

  def find_among(%__MODULE__{}, []), do: :fail

  defp do_find_among(state, vec, n, c, l) do
    i = find_among_search(state, vec, n, c, l, 0, n, 0, 0, false)
    find_among_resolve(state, vec, i, c, l)
  end

  # Binary search loop. Returns the index of the candidate entry whose
  # `s` is the (lexically) closest match at the cursor.
  defp find_among_search(state, vec, n, c, l, i, j, common_i, common_j, first_inspected) do
    k = i + Bitwise.bsr(j - i, 1)
    common = min(common_i, common_j)
    {s_k, _, _, _} = elem(vec, k)
    {diff, new_common} = compare_forward(state.current, c, l, s_k, common)

    {new_i, new_j, new_common_i, new_common_j} =
      if diff < 0 do
        {i, k, common_i, new_common}
      else
        {k, j, new_common, common_j}
      end

    cond do
      new_j - new_i > 1 ->
        find_among_search(state, vec, n, c, l, new_i, new_j, new_common_i, new_common_j, first_inspected)

      new_i > 0 ->
        new_i

      new_j == new_i ->
        new_i

      first_inspected ->
        new_i

      true ->
        find_among_search(state, vec, n, c, l, new_i, new_j, new_common_i, new_common_j, true)
    end
  end

  # Compare s_k against current[c..l] starting from `common` chars
  # already known to match. Returns `{diff, new_common}` where
  # `diff < 0` means s_k > current.
  defp compare_forward(current, c, l, s_k, common) do
    s_size = byte_size(s_k)
    do_compare_forward(current, c, l, s_k, s_size, common)
  end

  defp do_compare_forward(_current, _c, _l, _s_k, s_size, common) when common >= s_size,
    do: {0, common}

  defp do_compare_forward(current, c, l, s_k, s_size, common) do
    pos = c + common

    if pos >= l or pos >= byte_size(current) do
      {-1, common}
    else
      <<_::binary-size(^pos), curr_byte, _::binary>> = current
      <<_::binary-size(^common), s_byte, _::binary>> = s_k
      diff = curr_byte - s_byte

      if diff != 0 do
        {diff, common}
      else
        do_compare_forward(current, c, l, s_k, s_size, common + 1)
      end
    end
  end

  # Resolution loop: starting from candidate i, walk backward via
  # `substring_i` chain until a literal that matches at the cursor is
  # found and (if present) its filter function succeeds.
  defp find_among_resolve(state, vec, i, c, _l) do
    {s, substring_i, result, fun} = elem(vec, i)
    s_size = byte_size(s)

    if forward_match?(state.current, c, s, s_size) do
      advanced = %{state | cursor: c + s_size}

      case fun do
        nil ->
          {advanced, result}

        f when is_function(f, 1) ->
          case f.(advanced) do
            :fail ->
              follow_substring(state, vec, substring_i, c)

            %__MODULE__{} = new_state ->
              {%{new_state | cursor: c + s_size}, result}
          end
      end
    else
      follow_substring(state, vec, substring_i, c)
    end
  end

  defp follow_substring(_state, _vec, i, _c) when i < 0, do: :fail

  defp follow_substring(state, vec, i, c) do
    find_among_resolve(state, vec, i, c, nil)
  end

  defp forward_match?(current, c, s, s_size) do
    case current do
      <<_::binary-size(^c), prefix::binary-size(^s_size), _::binary>> -> prefix == s
      _ -> false
    end
  end

  @doc """
  Backward `among (...)` dispatcher.

  Same shape as `find_among/2` but searches before the cursor. On
  success, retreats the cursor by `byte_size(matched_string)`.

  ### Arguments

  * `state` is a `t:t/0`.

  * `entries` is a sorted list of `t:among_entry/0` tuples.

  ### Returns

  * `{updated_state, result}` on success.

  * `:fail` on no match.

  ### Examples

      iex> entries = [{"ing", -1, 1, nil}, {"run", -1, 2, nil}]
      iex> state = Snowball.Runtime.new("running")
      iex> state = %{state | cursor: 7, limit_backward: 0}
      iex> {%Snowball.Runtime{cursor: 4}, 1} = Snowball.Runtime.find_among_b(state, entries)

  """
  @spec find_among_b(t(), [among_entry()]) :: {t(), integer()} | fail()
  def find_among_b(%__MODULE__{cursor: cursor, limit_backward: lb} = state, entries)
      when is_list(entries) and entries != [] do
    vec = List.to_tuple(entries)
    n = tuple_size(vec)
    do_find_among_b(state, vec, n, cursor, lb)
  end

  def find_among_b(%__MODULE__{}, []), do: :fail

  defp do_find_among_b(state, vec, n, c, lb) do
    i = find_among_b_search(state, vec, n, c, lb, 0, n, 0, 0, false)
    find_among_b_resolve(state, vec, i, c, lb)
  end

  defp find_among_b_search(state, vec, n, c, lb, i, j, common_i, common_j, first_inspected) do
    k = i + Bitwise.bsr(j - i, 1)
    common = min(common_i, common_j)
    {s_k, _, _, _} = elem(vec, k)
    {diff, new_common} = compare_backward(state.current, c, lb, s_k, common)

    {new_i, new_j, new_common_i, new_common_j} =
      if diff < 0 do
        {i, k, common_i, new_common}
      else
        {k, j, new_common, common_j}
      end

    cond do
      new_j - new_i > 1 ->
        find_among_b_search(state, vec, n, c, lb, new_i, new_j, new_common_i, new_common_j, first_inspected)

      new_i > 0 ->
        new_i

      new_j == new_i ->
        new_i

      first_inspected ->
        new_i

      true ->
        find_among_b_search(state, vec, n, c, lb, new_i, new_j, new_common_i, new_common_j, true)
    end
  end

  # Backward compare: walk s_k right-to-left starting from
  # `len(s_k) - 1 - common` and the buffer right-to-left from c-1.
  defp compare_backward(current, c, lb, s_k, common) do
    s_size = byte_size(s_k)
    do_compare_backward(current, c, lb, s_k, s_size, common)
  end

  defp do_compare_backward(_current, _c, _lb, _s_k, s_size, common) when common >= s_size,
    do: {0, common}

  defp do_compare_backward(current, c, lb, s_k, s_size, common) do
    pos = c - 1 - common

    if pos < lb do
      {-1, common}
    else
      <<_::binary-size(^pos), curr_byte, _::binary>> = current
      s_pos = s_size - 1 - common
      <<_::binary-size(^s_pos), s_byte, _::binary>> = s_k
      diff = curr_byte - s_byte

      if diff != 0 do
        {diff, common}
      else
        do_compare_backward(current, c, lb, s_k, s_size, common + 1)
      end
    end
  end

  defp find_among_b_resolve(state, vec, i, c, lb) do
    {s, substring_i, result, fun} = elem(vec, i)
    s_size = byte_size(s)

    # The match start must be at or after limit_backward. Mirror Python's
    # `common_i >= len(w.s)` guard: reject entries whose start position
    # would precede lb (passed as nil when following the substring chain,
    # in which case the shorter suffix is inherently within bounds).
    if (lb == nil or c - s_size >= lb) and backward_match?(state.current, c, s, s_size) do
      retreated = %{state | cursor: c - s_size}

      case fun do
        nil ->
          {retreated, result}

        f when is_function(f, 1) ->
          case f.(retreated) do
            :fail ->
              follow_substring_b(state, vec, substring_i, c, lb)

            %__MODULE__{} = new_state ->
              {%{new_state | cursor: c - s_size}, result}
          end
      end
    else
      follow_substring_b(state, vec, substring_i, c, lb)
    end
  end

  defp follow_substring_b(_state, _vec, i, _c, _lb) when i < 0, do: :fail

  defp follow_substring_b(state, vec, i, c, lb) do
    find_among_b_resolve(state, vec, i, c, lb)
  end

  defp backward_match?(current, c, s, s_size) do
    start = c - s_size

    if start < 0 do
      false
    else
      case current do
        <<_::binary-size(^start), suffix::binary-size(^s_size), _::binary>> -> suffix == s
        _ -> false
      end
    end
  end
end
