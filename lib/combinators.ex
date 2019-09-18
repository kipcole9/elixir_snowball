defmodule Snowball.Combinators do
  import NimbleParsec

  def whitespace do
    ascii_string([?\s, ?\t, ?\n], min: 1)
    |> label("whitespace")
  end

  # <plus_or_minus> ::= + || -
  def plus_or_minus do
    ignore(optional(whitespace()))
    |> ascii_char([?+, ?-])
    |> ignore(optional(whitespace()))
  end

  def r_paren do
    ascii_char([?)])
    |> label("right parenthesis")
  end

  def l_paren do
    ascii_char([?(])
    |> label("left parenthesis")
  end

  # <letter>        ::= a || b || ... || z || A || B || ... || Z
  def letter do
    ascii_char([?a..?z, ?A..?Z])
    |> label("alphetic character")
  end

  # <digit>         ::= 0 || 1 || ... || 9
  def digit do
    ascii_char([?0..?9])
    |> label("digit")
  end

  def underscore do
    ascii_char([?_])
    |> label("underscore")
  end

  def single_quote do
    ascii_char([?'])
    |> label("single quote")
  end

  def equals do
    ascii_char([?=])
  end

  def plus_equals do
    string("+=")
  end

  def minus_equals do
    string("-=")
  end

  def mult_equals do
    string("*=")
  end

  def div_equals do
    string("/=")
  end

  def double_equals do
    string("==")
  end

  def not_equals do
    string("!=")
  end

  def less_than do
    string("<")
  end

  def less_than_or_equals do
    string("<=")
  end

  def greater_than do
    string(">")
  end

  def dollar do
    ascii_char([?$])
  end

  def greater_than_or_equals do
    string(">=")
  end

  def plus do
    string("+")
  end

  def minus do
    string("-")
  end

  def mult do
    string("*")
  end

  def div do
    string("/")
  end

  def l_bracket do
    string("[")
  end

  def r_bracket do
    string("]")
  end

  # <name>          ::= <letter> [ <letter> || <digit> || _ ]*
  def name do
    letter()
    |> repeat(choice([letter(), digit(), underscore()]))
    |> reduce({List, :to_string, []})
    |> reduce(:to_ast)
  end

  # <s_name>        ::= <name>
  def s_name do
    name()
    |> label("s_name")
  end

  # <i_name>        ::= <name>
  def i_name do
    name()
    |> label("integer variable name")
  end

  # <b_name>        ::= <name>
  def b_name do
    name()
    |> label("b_name")
  end

  # <r_name>        ::= <name>
  def r_name do
    name()
    |> label("r_name")
  end

  # <g_name>        ::= <name>
  def g_name do
    name()
    |> label("g_name")
  end

  # <literal string>::= '[<char>]*'
  def literal_string do
    ignore(single_quote())
    |> repeat(
      choice([
        utf8_string([{:not, ?'}, {:not, ?{}], min: 1),
        ignore(ascii_char([?{])) |> utf8_string([{:not, ?}}], min: 1) |> ignore(ascii_char([?}]))
      ])
    )
    |> ignore(single_quote())
    |> reduce({Enum, :join, []})
  end

  # <number>        ::= <digit> [ <digit> ]*
  def number do
    digit()
    |> repeat(digit())
  end

  #
  # S               ::= <s_name> || <literal string>
  def s do
    choice([
      s_name(),
      literal_string()
    ])
  end

  # G               ::= <g_name> || <literal string>
  def g do
    choice([
      g_name(),
      literal_string()
    ])
  end

  #
  # <declaration>   ::= strings ( [<s_name>]* ) ||
  #                     integers ( [<i_name>]* ) ||
  #                     booleans ( [<b_name>]* ) ||
  #                     routines ( [<r_name>]* ) ||
  #                     externals ( [<r_name>]* ) ||
  #                     groupings ( [<g_name>]* )
  def declaration do
    choice([
      string_declarations(),
      integer_declarations(),
      boolean_declarations(),
      routine_declarations(),
      external_declarations(),
      groupings_declarations()
    ])
  end

  def string_declarations do
    string("strings")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(s_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("string declarations")
  end

  def integer_declarations do
    string("integers")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(i_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("integer declarations")
  end

  def boolean_declarations do
    string("booleans")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(b_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("boolean declarations")
  end

  def routine_declarations do
    string("routines")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(r_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("routine declarations")
  end

  def external_declarations do
    string("externals")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(r_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("external declarations")
  end

  def groupings_declarations do
    string("groupings")
    |> ignore(optional(whitespace()))
    |> ignore(l_paren())
    |> repeat(ignore(optional(whitespace())) |> concat(g_name()))
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> reduce(:wrap_declarations)
    |> label("groupings declarations")
  end

  def wrap_declarations([type | rest]) do
    {:declare, [], [String.to_atom(type), rest]}
  end

  # <r_definition>  ::= define <r_name> as C
  def r_definition do
    string("define")
    |> ignore(whitespace())
    |> concat(r_name())
    |> ignore(whitespace())
    |> string("as")
    |> ignore(whitespace())
    |> parsec(:c)
  end

  # <g_definition>  ::= define <g_name> G [ <plus_or_minus> G ]*
  def g_definition do
    string("define")
    |> ignore(whitespace())
    |> concat(g_name())
    |> ignore(whitespace())
    |> concat(g())
    |> repeat(plus_or_minus() |> concat(g()))
  end

  # <i_assign>      ::= $ <i_name> = AE ||
  #                     $ <i_name> += AE || $ <i_name> -= AE ||
  #                     $ <i_name> *= AE || $ <i_name> /= AE
  def i_assign do
    choice([
      ignore(dollar())
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(equals())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      ignore(dollar())
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(plus_equals())
      |> parsec(:ae),
      ignore(dollar())
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(minus_equals())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      ignore(dollar())
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(mult_equals())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      ignore(dollar())
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(div_equals())
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
    ])
    |> reduce(:to_ast)
  end

  # <i_test_op>     ::= == || != || > || >= || < || <=
  def i_test_op do
    choice([
      double_equals(),
      equals(),
      not_equals(),
      greater_than_or_equals(),
      greater_than(),
      less_than_or_equals(),
      less_than()
    ])
  end

  # <i_test>        ::= $ ( AE <i_test_op> AE ) ||
  #                     $ <i_name> <i_test_op> AE
  def i_test do
    choice([
      dollar()
      |> ignore(optional(whitespace()))
      |> concat(l_paren())
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(i_test_op())
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(r_paren()),
      dollar()
      |> ignore(optional(whitespace()))
      |> concat(i_name())
      |> ignore(optional(whitespace()))
      |> concat(i_test_op())
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
    ])
  end

  # <s_command>     ::= $ <s_name> C
  def s_command do
    dollar() |> concat(s_name()) |> ignore(optional(whitespace())) |> parsec(:c)
  end

  def among_expression do
    literal_string()
    |> ignore(whitespace())
    |> repeat(
      choice([
        r_name(),
        l_paren()
        |> ignore(optional(whitespace()))
        |> parsec(:c)
        |> ignore(optional(whitespace()))
        |> concat(r_paren())
      ])
    )
  end

  def do_ do
    string("do")
    |> ignore(whitespace())
    |> parsec(:c)
    |> label("do")
  end

  def set do
    string("set")
    |> ignore(whitespace())
    |> concat(b_name())
    |> reduce(:to_ast)
    |> label("set")
  end

  def unset do
    string("unset")
    |> ignore(whitespace())
    |> concat(b_name())
    |> reduce(:to_ast)
    |> label("unset")
  end

  def not_ do
    string("not")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("not")
  end

  def test do
    string("test")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("test")
  end

  def try_ do
    string("try")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("try")
  end

  def fail do
    string("fail")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("fail")
  end

  def goto do
    string("goto")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("goto")
  end

  def gopast do
    string("gopast")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("gopast")
  end

  def repeat do
    string("repeat")
    |> ignore(whitespace())
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("repeat")
  end

  def loop do
    string("loop")
    |> ignore(whitespace())
    |> parsec(:ae)
    |> ignore(optional(whitespace()))
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("loop")
  end

  def atleast do
    string("atleast")
    |> ignore(whitespace())
    |> parsec(:ae)
    |> ignore(optional(whitespace()))
    |> parsec(:c)
    |> reduce(:to_ast)
    |> label("atleast")
  end

  def backwards do
    string("backwardsmode")
    |> ignore(whitespace())
    |> ignore(l_paren())
    |> parsec(:c)
    |> ignore(optional(whitespace()))
    |> ignore(r_paren())
    |> label("backwards mode")
  end

  def delete do
    string("delete")
  end

  def string_escapes do
    ignore(string("stringescapes"))
    |> ignore(whitespace())
    |> ascii_char([])
    |> ascii_char([])
    |> reduce(:string_escapes)
  end

  def string_escapes(chars) do
    {:escape, chars}
  end

  def to_ast([variable]) do
    {String.to_atom(variable), [], Elixir}
  end

  def to_ast([{_, _, _} = left, op, builtin]) when is_binary(builtin) do
    right = {String.to_atom(builtin), [], []}
    {List.to_atom([op]), [], [left, right]}
  end

  def to_ast([{_, _, _} = left, op, {_, _, _} = right]) do
    {List.to_atom([op]), [], [left, right]}
  end

  def to_ast([function | args]) do
    {String.to_atom(function), [], args}
  end

  #
  #
  #
  # synonyms:      <+ for insert
end
