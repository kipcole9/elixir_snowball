defmodule Snowball.Lexer do
  @moduledoc """
  Tokeniser for the Snowball string-processing language.

  Converts a Snowball source binary into a flat list of `t:token/0` tuples.
  NimbleParsec is used to compose the individual token parsers; the public
  `tokenize/1` function wraps the generated parser and strips whitespace and
  comments from the result.

  ## Token format

  Each token is a tagged tuple `{tag, value, line}`:

  * `{:integer, n, line}` — decimal or hexadecimal integer literal.

  * `{:string, s, line}` — single-quoted string literal (UTF-8 binary).
    `{'}` inside the string produces a literal apostrophe; `{X}` for a single
    char `X` produces that char literally.

  * `{:name, s, line}` — identifier (not a reserved keyword).

  * `{:keyword, atom, line}` — reserved keyword, e.g. `{:keyword, :define, 5}`.

  * `{:sym, atom, line}` — punctuation or operator, e.g. `{:sym, :lparen, 3}`.

  """

  import NimbleParsec

  # --------------------------------------------------------------------------
  # Whitespace and comments — discarded from the token stream.
  # --------------------------------------------------------------------------

  whitespace = ascii_string([?\s, ?\t, ?\r, ?\n], min: 1)

  line_comment =
    string("//")
    |> repeat(lookahead_not(ascii_char([?\n])) |> utf8_char([]))
    |> optional(ascii_char([?\n]))

  block_comment =
    string("/*")
    |> repeat(
      lookahead_not(string("*/"))
      |> choice([
        ascii_char([?\n]),
        utf8_char([])
      ])
    )
    |> string("*/")

  ignored = choice([whitespace, line_comment, block_comment])

  # --------------------------------------------------------------------------
  # Integer literals — decimal or hex (the `hex` keyword prefix is handled
  # at the analyser level; the lexer just produces integer values).
  # --------------------------------------------------------------------------

  decimal_digit = ascii_char([?0..?9])

  integer_token =
    times(decimal_digit, min: 1)
    |> reduce({List, :to_integer, []})
    |> post_traverse({__MODULE__, :_tag_integer, []})

  # --------------------------------------------------------------------------
  # String literals — delimited by single quotes.
  # The escape sequence `{X}` inside the string produces X literally.
  # `{'}` is the canonical way to embed an apostrophe.
  # --------------------------------------------------------------------------

  escaped_char =
    ignore(ascii_char([?{]))
    |> repeat(
      lookahead_not(ascii_char([?}]))
      |> utf8_char([])
    )
    |> ignore(ascii_char([?}]))
    |> reduce({__MODULE__, :_escape_chars, []})

  plain_char =
    lookahead_not(ascii_char([?', ?{]))
    |> utf8_char([])

  string_body =
    repeat(choice([escaped_char, plain_char]))
    |> reduce({List, :to_string, []})

  string_token =
    ignore(ascii_char([?']))
    |> concat(string_body)
    |> ignore(ascii_char([?']))
    |> post_traverse({__MODULE__, :_tag_string, []})

  # --------------------------------------------------------------------------
  # Keywords and names — a run of ASCII letters and underscores.
  # --------------------------------------------------------------------------

  # Snowball identifiers are ASCII letters, underscores, and digits.
  ident_char = ascii_char([?a..?z, ?A..?Z, ?_, ?0..?9])

  word_token =
    times(ident_char, min: 1)
    |> reduce({List, :to_string, []})
    |> post_traverse({__MODULE__, :_classify_word, []})

  # --------------------------------------------------------------------------
  # Symbol tokens — longest-match first for multi-char symbols.
  # --------------------------------------------------------------------------

  symbol_token =
    choice([
      # Two-char symbols first (longest match).
      string("!=") |> replace(:ne),
      string("<-") |> replace(:slice_from),
      string("<+") |> replace(:insert_sym),
      string("<=") |> replace(:le),
      string("->") |> replace(:slice_to),
      string("-=") |> replace(:minus_assign),
      string("*=") |> replace(:multiply_assign),
      string("/=") |> replace(:divide_assign),
      string("+=") |> replace(:plus_assign),
      string("==") |> replace(:eq),
      string("=>") |> replace(:assign_to),
      string(">=") |> replace(:ge),
      # Single-char symbols.
      ascii_char([?(]) |> replace(:lparen),
      ascii_char([?)]) |> replace(:rparen),
      ascii_char([?[]) |> replace(:lbracket),
      ascii_char([?]]) |> replace(:rbracket),
      ascii_char([?<]) |> replace(:lt),
      ascii_char([?>]) |> replace(:gt),
      ascii_char([?=]) |> replace(:assign),
      ascii_char([?+]) |> replace(:plus),
      ascii_char([?-]) |> replace(:minus),
      ascii_char([?*]) |> replace(:multiply),
      ascii_char([?/]) |> replace(:divide),
      ascii_char([?$]) |> replace(:dollar),
      ascii_char([??]) |> replace(:debug),
      ascii_char([?{]) |> replace(:lbrace),
      ascii_char([?}]) |> replace(:rbrace)
    ])
    |> post_traverse({__MODULE__, :_tag_sym, []})

  # --------------------------------------------------------------------------
  # Top-level tokeniser: zero or more (ignored | token).
  # --------------------------------------------------------------------------

  defparsec(
    :_tokenize_impl,
    repeat(
      choice([
        ignore(ignored),
        integer_token,
        string_token,
        word_token,
        symbol_token
      ])
    )
    |> eos()
  )

  # --------------------------------------------------------------------------
  # Public API.
  # --------------------------------------------------------------------------

  @typedoc """
  A single Snowball token.

  * `{:integer, n, line}` — integer literal.

  * `{:string, s, line}` — string literal (UTF-8 binary).

  * `{:name, s, line}` — identifier.

  * `{:keyword, atom, line}` — reserved keyword.

  * `{:sym, atom, line}` — punctuation / operator.

  """
  @type token ::
          {:integer, integer(), pos_integer()}
          | {:string, binary(), pos_integer()}
          | {:name, binary(), pos_integer()}
          | {:keyword, atom(), pos_integer()}
          | {:sym, atom(), pos_integer()}

  @doc """
  Tokenize a Snowball source binary.

  ### Arguments

  * `source` is the UTF-8 binary source text.

  ### Returns

  * `{:ok, tokens}` — a list of `t:token/0` tuples in source order.

  * `{:error, reason, rest, line}` — the tokeniser failed at `rest` on
    `line` with the given `reason`.

  ### Examples

      iex> Snowball.Lexer.tokenize("define")
      {:ok, [{:keyword, :define, 1}]}

      iex> Snowball.Lexer.tokenize("'hello'")
      {:ok, [{:string, "hello", 1}]}

  """
  @spec tokenize(binary()) ::
          {:ok, [token()]} | {:error, binary(), binary(), pos_integer()}
  def tokenize(source) when is_binary(source) do
    case _tokenize_impl(source, context: %{line: 1}) do
      {:ok, tokens, _rest, _context, _position, _offset} ->
        {:ok, tokens}

      {:error, reason, rest, _context, {line, _col}, _offset} ->
        {:error, reason, rest, line}
    end
  end

  # --------------------------------------------------------------------------
  # Post-traversal callbacks — attach line numbers and classify tokens.
  # --------------------------------------------------------------------------

  # These are called by NimbleParsec with `(rest, args, context, position, offset)`.
  # `position` is `{line, column}` at the *start* of the matched text.

  @doc false
  def _tag_integer(rest, [value], context, {line, _col}, _offset) do
    {rest, [{:integer, value, line}], context}
  end

  @doc false
  def _tag_string(rest, [value], context, {line, _col}, _offset) do
    {rest, [{:string, value, line}], context}
  end

  @doc false
  def _tag_sym(rest, [sym], context, {line, _col}, _offset) do
    {rest, [{:sym, sym, line}], context}
  end

  @doc false
  def _classify_word(rest, [word], context, {line, _col}, _offset) do
    token =
      case keyword_atom(word) do
        nil -> {:name, word, line}
        atom -> {:keyword, atom, line}
      end

    {rest, [token], context}
  end

  # Collapse the codepoints from a `{...}` escape into a string.
  @doc false
  def _escape_chars(codepoints) when is_list(codepoints) do
    List.to_string(codepoints)
  end

  # --------------------------------------------------------------------------
  # Keyword table.
  # --------------------------------------------------------------------------

  @keywords %{
    "as" => :as,
    "do" => :do,
    "or" => :or,
    "and" => :and,
    "for" => :for,
    "get" => :get,
    "hex" => :hex,
    "hop" => :hop,
    "len" => :len,
    "non" => :non,
    "not" => :not,
    "set" => :set,
    "try" => :try,
    "fail" => :fail,
    "goto" => :goto,
    "loop" => :loop,
    "next" => :next,
    "size" => :size,
    "test" => :test,
    "true" => :true,
    "among" => :among,
    "false" => :false,
    "lenof" => :lenof,
    "limit" => :limit,
    "unset" => :unset,
    "atmark" => :atmark,
    "attach" => :attach,
    "cursor" => :cursor,
    "define" => :define,
    "delete" => :delete,
    "gopast" => :gopast,
    "insert" => :insert,
    "maxint" => :maxint,
    "minint" => :minint,
    "repeat" => :repeat,
    "sizeof" => :sizeof,
    "tomark" => :tomark,
    "atleast" => :atleast,
    "atlimit" => :atlimit,
    "decimal" => :decimal,
    "reverse" => :reverse,
    "setmark" => :setmark,
    "strings" => :strings,
    "tolimit" => :tolimit,
    "booleans" => :booleans,
    "integers" => :integers,
    "routines" => :routines,
    "setlimit" => :setlimit,
    "backwards" => :backwards,
    "externals" => :externals,
    "groupings" => :groupings,
    "stringdef" => :stringdef,
    "substring" => :substring,
    "backwardmode" => :backwardmode,
    "stringescapes" => :stringescapes
  }

  defp keyword_atom(word), do: Map.get(@keywords, word)
end
