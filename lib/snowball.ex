defmodule Snowball do
  import NimbleParsec
  import Snowball.Combinators

  def parse(input, rule \\ :program) do
    case apply(__MODULE__, rule, [input]) do
      {:ok, result, "", _state, {_line, _}, _character} ->
        {:ok, result}

      {:ok, _result, rest, _state, {line, _}, character} ->
        {:error,
         {Snowball.ParseError,
          "Couldn't parse file after line #{line} character #{character}:\n#{inspect(rest)}"}}
    end
  rescue
    exception in [Snowball.ParseError] ->
      {:error, {Snowball.ParseError, exception.message}}
  end

  defparsec :declaration, declaration()
  defparsec :literal, literal_string()

  defparsec :program,
            parsec(:p)
            |> ignore(optional(whitespace()))
            |> eos()

  # P              ::=  [P]* || <declaration> ||
  #                     <r_definition> || <g_definition> ||
  #                     backwardmode ( P )
  defparsec :p,
            repeat(
              ignore(optional(whitespace()))
              |> choice([
                declaration(),
                string_escapes(),
                r_definition(),
                g_definition(),
                backwards()
              ])
            )

  #
  # C               ::= ( [C]* ) ||
  #                     <i_assign> || <i_test> || <s_command> || C or C || C and C ||
  #                     not C || test C || try C || do C || fail C ||
  #                     goto C || gopast C || repeat C || loop AE C ||
  #                     atleast AE C || S || = S || insert S || attach S ||
  #                     <- S || delete ||  hop AE || next ||
  #                     => <s_name> || [ || ] || -> <s_name> ||
  #                     setmark <i_name> || tomark AE || atmark AE ||
  #                     tolimit || atlimit || setlimit C for C ||
  #                     backwards C || reverse C || substring ||
  #                     among ( [<literal string> [<r_name>] || (C)]* ) ||
  #                     set <b_name> || unset <b_name> || <b_name> ||
  #                     <r_name> || <g_name> || non [-] <g_name> ||
  #                     true || false || ?
  defparsec(
    :c,
    repeat(
      ignore(optional(whitespace()))
      |> choice([
        l_bracket(),
        r_bracket(),
        i_assign(),
        i_test(),
        s_command(),

        # Built-ins must come before
        # variable names
        do_(),
        set(),
        unset(),
        delete(),
        not_(),
        test(),
        try_(),
        fail(),
        goto(),
        gopast(),
        repeat(),
        loop(),
        atleast(),
        s(),

        # Variable names
        b_name(),
        r_name(),
        g_name(),

        equals() |> ignore(optional(whitespace())) |> concat(s()),
        string("insert") |> ignore(whitespace()) |> concat(s()),
        string("attach") |> ignore(whitespace()) |> concat(s()),
        string("<-") |> ignore(optional(whitespace())) |> concat(s()),
        string("hop") |> ignore(whitespace()) |> parsec(:ae),
        string("next"),
        string("=>") |> ignore(optional(whitespace())) |> concat(s_name()),
        string("->") |> ignore(optional(whitespace())) |> concat(s_name()),
        string("setmark") |> ignore(whitespace()) |> concat(i_name()),
        string("tomark") |> ignore(whitespace()) |> concat(i_name()),
        string("atmark") |> ignore(whitespace()) |> concat(i_name()),
        string("tolimit"),
        string("atlimit"),
        string("setlimit")
        |> ignore(whitespace())
        |> parsec(:c)
        |> ignore(whitespace())
        |> string("for")
        |> ignore(whitespace())
        |> parsec(:c),
        string("backwards") |> ignore(whitespace()) |> parsec(:c),
        string("reverse") |> ignore(whitespace()) |> parsec(:c),
        string("substring"),
        string("among")
        |> ignore(whitespace())
        |> concat(l_paren())
        |> ignore(optional(whitespace()))
        |> concat(among_expression())
        |> ignore(optional(whitespace()))
        |> concat(r_paren()),

        string("non")
        |> ignore(whitespace())
        |> concat(minus())
        |> ignore(optional(whitespace()))
        |> concat(g_name()),
        string("true"),
        string("false"),
        ascii_char([??]),

        # Recursive parts come last
        ignore(l_paren())
        |> parsec(:c)
        |> ignore(optional(whitespace()))
        |> ignore(r_paren()),

        # parsec(:c)
        # |> ignore(optional(whitespace()))
        # |> string("or")
        # |> ignore(optional(whitespace()))
        # |> parsec(:c),
        # parsec(:c)
        # |> ignore(optional(whitespace()))
        # |> string("and")
        # |> ignore(optional(whitespace()))
        # |> parsec(:c)
      ])
    )
  )



  # AE              ::= (AE) ||
  #                     AE + AE || AE - AE || AE * AE || AE / AE || - AE ||
  #                     maxint || minint || cursor || limit ||
  #                     size || sizeof <s_name> ||
  #                     len || lenof <s_name> ||
  #                     <i_name> || <number>
  defparsec(
    :ae,
    choice([
      string("maxint"),
      string("minint"),
      string("cursor"),
      string("limit"),
      string("size"),
      string("sizeof"),
      string("lenof") |> ignore(whitespace()) |> concat(s_name()),
      i_name(),
      number(),
      l_paren()
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
      |> optional(whitespace())
      |> concat(r_paren()),
      parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(plus())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(minus())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(mult())
      |> ignore(optional(whitespace()))
      |> parsec(:ae),
      parsec(:ae)
      |> ignore(optional(whitespace()))
      |> concat(div())
      |> ignore(optional(whitespace()))
      |> parsec(:ae)
    ])
    |> reduce(:to_ast)
  )
end
