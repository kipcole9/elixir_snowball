defmodule Snowball.LexerTest do
  use ExUnit.Case, async: true
  doctest Snowball.Lexer

  alias Snowball.Lexer

  defp lex!(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    tokens
  end

  defp types(tokens), do: Enum.map(tokens, fn {tag, _, _} -> tag end)
  defp values(tokens), do: Enum.map(tokens, fn {_, v, _} -> v end)
  defp lines(tokens), do: Enum.map(tokens, fn {_, _, l} -> l end)

  # -----------------------------------------------------------------------
  # Keywords
  # -----------------------------------------------------------------------

  test "tokenizes every reserved keyword" do
    for {word, atom} <- [
          {"define", :define},
          {"routines", :routines},
          {"externals", :externals},
          {"integers", :integers},
          {"booleans", :booleans},
          {"groupings", :groupings},
          {"strings", :strings},
          {"among", :among},
          {"substring", :substring},
          {"backwards", :backwards},
          {"backwardmode", :backwardmode},
          {"stringescapes", :stringescapes},
          {"do", :do},
          {"try", :try},
          {"not", :not},
          {"test", :test},
          {"fail", :fail},
          {"set", :set},
          {"unset", :unset},
          {"true", :true},
          {"false", :false},
          {"and", :and},
          {"or", :or},
          {"goto", :goto},
          {"gopast", :gopast},
          {"repeat", :repeat},
          {"loop", :loop},
          {"atlimit", :atlimit},
          {"tolimit", :tolimit},
          {"atmark", :atmark},
          {"tomark", :tomark},
          {"setmark", :setmark},
          {"hop", :hop},
          {"next", :next},
          {"non", :non},
          {"insert", :insert},
          {"delete", :delete},
          {"attach", :attach},
          {"reverse", :reverse},
          {"cursor", :cursor},
          {"limit", :limit},
          {"size", :size},
          {"sizeof", :sizeof},
          {"len", :len},
          {"lenof", :lenof},
          {"maxint", :maxint},
          {"minint", :minint},
          {"atleast", :atleast},
          {"setlimit", :setlimit},
          {"hex", :hex},
          {"decimal", :decimal},
          {"get", :get},
          {"as", :as},
          {"for", :for},
          {"stringdef", :stringdef}
        ] do
      [{:keyword, ^atom, 1}] = lex!(word)
    end
  end

  test "name is not a keyword" do
    [{:name, "myvar", 1}] = lex!("myvar")
  end

  test "mixed keyword and name on one line" do
    tokens = lex!("define foo as ()")
    assert types(tokens) == [:keyword, :name, :keyword, :sym, :sym]
    assert values(tokens) == [:define, "foo", :as, :lparen, :rparen]
  end

  # -----------------------------------------------------------------------
  # Integer literals
  # -----------------------------------------------------------------------

  test "single-digit integer" do
    [{:integer, 0, 1}] = lex!("0")
  end

  test "multi-digit integer" do
    [{:integer, 42, 1}] = lex!("42")
  end

  test "large integer" do
    [{:integer, 123456, 1}] = lex!("123456")
  end

  # -----------------------------------------------------------------------
  # String literals
  # -----------------------------------------------------------------------

  test "empty string" do
    [{:string, "", 1}] = lex!("''")
  end

  test "simple string" do
    [{:string, "hello", 1}] = lex!("'hello'")
  end

  test "string with escaped apostrophe" do
    # Snowball source: '{'}'  (apostrophe inside {…} escape)
    [{:string, "'", 1}] = lex!("'{'}'")
  end

  test "string with braced escape chars" do
    # {ab} inside a string produces "ab"
    [{:string, "ab", 1}] = lex!("'{ab}'")
  end

  test "string with leading and trailing content" do
    [{:string, "aeo", 1}] = lex!("'aeo'")
  end

  # -----------------------------------------------------------------------
  # Symbols
  # -----------------------------------------------------------------------

  test "parens" do
    tokens = lex!("()")
    assert values(tokens) == [:lparen, :rparen]
  end

  test "brackets (slice marks)" do
    tokens = lex!("[]")
    assert values(tokens) == [:lbracket, :rbracket]
  end

  test "slice_from <-" do
    [{:sym, :slice_from, 1}] = lex!("<-")
  end

  test "slice_to ->" do
    [{:sym, :slice_to, 1}] = lex!("->")
  end

  test "assign_to =>" do
    [{:sym, :assign_to, 1}] = lex!("=>")
  end

  test "assign =" do
    [{:sym, :assign, 1}] = lex!("=")
  end

  test "eq ==" do
    [{:sym, :eq, 1}] = lex!("==")
  end

  test "ne !=" do
    [{:sym, :ne, 1}] = lex!("!=")
  end

  test "lt <" do
    [{:sym, :lt, 1}] = lex!("<")
  end

  test "le <=" do
    [{:sym, :le, 1}] = lex!("<=")
  end

  test "gt >" do
    [{:sym, :gt, 1}] = lex!(">")
  end

  test "ge >=" do
    [{:sym, :ge, 1}] = lex!(">=")
  end

  test "arithmetic operators" do
    tokens = lex!("+ - * /")
    assert values(tokens) == [:plus, :minus, :multiply, :divide]
  end

  test "dollar sign" do
    [{:sym, :dollar, 1}] = lex!("$")
  end

  # -----------------------------------------------------------------------
  # Whitespace and comments
  # -----------------------------------------------------------------------

  test "whitespace between tokens is discarded" do
    tokens = lex!("  define   foo  ")
    assert types(tokens) == [:keyword, :name]
  end

  test "line comment is ignored" do
    tokens = lex!("define // this is a comment\nfoo")
    assert types(tokens) == [:keyword, :name]
  end

  test "block comment is ignored" do
    tokens = lex!("define /* comment */ foo")
    assert types(tokens) == [:keyword, :name]
  end

  # -----------------------------------------------------------------------
  # Line numbers
  # -----------------------------------------------------------------------

  test "line numbers are tracked across newlines" do
    tokens = lex!("define\nfoo\nbar")
    assert lines(tokens) == [1, 2, 3]
  end

  test "line numbers advance past comments" do
    tokens = lex!("a\n// comment\nb")
    assert lines(tokens) == [1, 3]
  end

  # -----------------------------------------------------------------------
  # Real Snowball snippet
  # -----------------------------------------------------------------------

  test "tokenizes a real Snowball snippet" do
    source = """
    define Step_1a as (
        [substring] among (
            'ied' 'ies' (delete)
        )
    )
    """

    {:ok, tokens} = Lexer.tokenize(source)
    assert Enum.any?(tokens, fn t -> t == {:keyword, :define, 1} end)
    assert Enum.any?(tokens, fn t -> t == {:keyword, :among, 2} end)
    assert Enum.any?(tokens, fn t -> t == {:string, "ied", 3} end)
    assert Enum.any?(tokens, fn t -> t == {:keyword, :delete, 3} end)
  end

  # -----------------------------------------------------------------------
  # Error handling
  # -----------------------------------------------------------------------

  test "returns error for invalid input" do
    assert {:error, _reason, _rest, _line} = Lexer.tokenize("@invalid")
  end
end
