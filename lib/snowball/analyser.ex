defmodule Snowball.Analyser do
  @moduledoc """
  Parses a Snowball token stream into a typed AST with a symbol table.

  Accepts the output of `Snowball.Lexer.tokenize/1` and returns a
  `t:program/0` map that the code generator consumes.

  ## AST node shapes

  All nodes are plain maps with at least a `:kind` atom and a `:line`
  integer. The primary node kinds are:

  * `%{kind: :program, symbols: symbol_table, defs: [node]}` — top-level.

  * `%{kind: :define_routine, name: binary, body: node, line: n}`.

  * `%{kind: :define_grouping, name: binary, strings: [binary], line: n}`.

  * Command nodes — see `t:node/0`.

  """

  # ------------------------------------------------------------------
  # Public types
  # ------------------------------------------------------------------

  @typedoc "Symbol types that names can be declared as."
  @type symbol_type :: :integer | :boolean | :string | :grouping | :routine | :external

  @typedoc "A symbol table entry."
  @type symbol :: %{type: symbol_type(), mode: :unknown | :forward | :backward}

  @typedoc "The symbol table — map from name string to symbol."
  @type symbol_table :: %{optional(binary()) => symbol()}

  @typedoc "An AST node (map with at least :kind and :line)."
  @type ast_node :: map()

  @typedoc "The top-level program node."
  @type program :: %{kind: :program, symbols: symbol_table(), defs: [ast_node()]}

  # ------------------------------------------------------------------
  # Internal parser state
  # ------------------------------------------------------------------

  defstruct tokens: [],
            symbols: %{},
            mode: :forward,
            errors: []

  @type t :: %__MODULE__{
          tokens: [Snowball.Lexer.token()],
          symbols: symbol_table(),
          mode: :forward | :backward,
          errors: [{binary(), pos_integer()}]
        }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Analyse a token list produced by `Snowball.Lexer.tokenize/1`.

  ### Arguments

  * `tokens` is the flat list of `t:Snowball.Lexer.token/0` tuples.

  ### Returns

  * `{:ok, program}` — the program AST.

  * `{:error, [{reason, line}]}` — one or more parse errors.

  ### Examples

      iex> {:ok, tokens} = Snowball.Lexer.tokenize("integers ( p1 )")
      iex> {:ok, prog} = Snowball.Analyser.analyse(tokens)
      iex> prog.kind
      :program

  """
  @spec analyse([Snowball.Lexer.token()]) ::
          {:ok, program()} | {:error, [{binary(), non_neg_integer()}]}
  def analyse(tokens) when is_list(tokens) do
    state = %__MODULE__{tokens: tokens}
    {defs, state} = read_program(state)

    if state.errors == [] do
      {:ok, %{kind: :program, symbols: state.symbols, defs: defs}}
    else
      {:error, Enum.reverse(state.errors)}
    end
  end

  # ------------------------------------------------------------------
  # Token-stream primitives
  # ------------------------------------------------------------------

  defp peek(%__MODULE__{tokens: [tok | _]}), do: tok
  defp peek(%__MODULE__{tokens: []}), do: nil

  defp advance(%__MODULE__{tokens: [_ | rest]} = state), do: %{state | tokens: rest}
  defp advance(%__MODULE__{tokens: []} = state), do: state

  defp consume(%__MODULE__{tokens: [tok | rest]} = state), do: {tok, %{state | tokens: rest}}
  defp consume(%__MODULE__{tokens: []} = state), do: {nil, state}

  # Require a specific keyword; emit error and don't advance on mismatch.
  defp expect_keyword(state, atom) do
    case peek(state) do
      {:keyword, ^atom, _} -> advance(state)
      tok -> add_error(state, "expected '#{atom}'", tok_line(tok))
    end
  end

  # Require a specific symbol; emit error and don't advance on mismatch.
  defp expect_sym(state, atom) do
    case peek(state) do
      {:sym, ^atom, _} -> advance(state)
      tok -> add_error(state, "expected '#{atom}'", tok_line(tok))
    end
  end

  defp tok_line(nil), do: 0
  defp tok_line({_, _, line}), do: line

  defp current_line(%__MODULE__{tokens: [tok | _]}), do: tok_line(tok)
  defp current_line(%__MODULE__{}), do: 0

  defp add_error(state, reason, line) do
    %{state | errors: [{reason, line} | state.errors]}
  end

  # ------------------------------------------------------------------
  # Symbol table helpers
  # ------------------------------------------------------------------

  defp declare(state, name, type, line) do
    if Map.has_key?(state.symbols, name) do
      add_error(state, "'#{name}' re-declared", line)
    else
      entry = %{type: type, mode: :unknown}
      %{state | symbols: Map.put(state.symbols, name, entry)}
    end
  end

  defp resolve(state, name, expected_type, line) do
    case Map.get(state.symbols, name) do
      nil ->
        {add_error(state, "'#{name}' undeclared", line), nil}

      %{type: ^expected_type} = sym ->
        {state, sym}

      %{type: :external} when expected_type == :routine ->
        # externals are callable as routines
        {state, Map.get(state.symbols, name)}

      %{type: actual} ->
        {add_error(state, "'#{name}' has type #{actual}, expected #{expected_type}", line), nil}
    end
  end

  # ------------------------------------------------------------------
  # Top-level program
  # ------------------------------------------------------------------

  defp read_program(state) do
    read_program_loop(state, [], false)
  end

  defp read_program_loop(state, acc, stop_at_rparen) do
    case peek(state) do
      nil ->
        {Enum.reverse(acc), state}

      {:sym, :rparen, _} when stop_at_rparen ->
        # Stop without consuming the ')'; caller will consume it.
        {Enum.reverse(acc), state}

      {:keyword, :integers, _} ->
        state = read_names(advance(state), :integer)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :booleans, _} ->
        state = read_names(advance(state), :boolean)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :strings, _} ->
        state = read_names(advance(state), :string)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :routines, _} ->
        state = read_names(advance(state), :routine)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :externals, _} ->
        state = read_names(advance(state), :external)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :groupings, _} ->
        state = read_names(advance(state), :grouping)
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :stringescapes, _} ->
        state = skip_stringescapes(advance(state))
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :stringdef, _} ->
        state = skip_stringdef(advance(state))
        read_program_loop(state, acc, stop_at_rparen)

      {:keyword, :backwardmode, _} ->
        {nodes, state} = read_backwardmode(advance(state))
        read_program_loop(state, acc ++ nodes, stop_at_rparen)

      {:keyword, :define, line} ->
        {node, state} = read_define(advance(state), line)
        read_program_loop(state, if(node, do: [node | acc], else: acc), stop_at_rparen)

      {_, _, line} = tok ->
        state = add_error(state, "unexpected token '#{format_tok(tok)}'", line)
        read_program_loop(advance(state), acc, stop_at_rparen)
    end
  end

  # ------------------------------------------------------------------
  # Declaration parsers
  # ------------------------------------------------------------------

  # integers/booleans/strings/routines/externals/groupings ( name* )
  defp read_names(state, type) do
    state = expect_sym(state, :lparen)
    read_names_loop(state, type)
  end

  defp read_names_loop(state, type) do
    case peek(state) do
      {:sym, :rparen, _} ->
        advance(state)

      {:name, name, line} ->
        state = declare(advance(state), name, type, line)
        read_names_loop(state, type)

      # len and lenof can be re-declared as names (context-sensitive keyword)
      {:keyword, :len, line} ->
        state = declare(advance(state), "len", type, line)
        read_names_loop(state, type)

      {:keyword, :lenof, line} ->
        state = declare(advance(state), "lenof", type, line)
        read_names_loop(state, type)

      nil ->
        add_error(state, "unexpected end of input in name list", 0)

      tok ->
        state = expect_sym(state, :rparen)
        state = add_error(state, "expected name in declaration, got '#{format_tok(tok)}'", tok_line(tok))
        state
    end
  end

  # stringescapes XY — consume the two escape-delimiter characters.
  # In practice all algorithms use `{}`, which the lexer emits as
  # {:sym, :lbrace, _} and {:sym, :rbrace, _}.
  defp skip_stringescapes(state) do
    state =
      case peek(state) do
        {:sym, :lbrace, _} -> advance(state)
        {:string, _, _} -> advance(state)
        {:name, _, _} -> advance(state)
        _ -> state
      end

    case peek(state) do
      {:sym, :rbrace, _} -> advance(state)
      _ -> state
    end
  end

  # stringdef NAME 'string' — we skip these for now (they define macros
  # inside string literals; rare in practice).
  defp skip_stringdef(state) do
    # consume the name and the string
    state =
      case peek(state) do
        {:name, _, _} -> advance(state)
        _ -> state
      end

    case peek(state) do
      {:string, _, _} -> advance(state)
      _ -> state
    end
  end

  # backwardmode ( declarations ) — same as top-level but with mode=:backward
  defp read_backwardmode(state) do
    state = expect_sym(state, :lparen)
    old_mode = state.mode
    state = %{state | mode: :backward}
    # stop_at_rparen: true — loop returns when it sees ')' without consuming it.
    {nodes, state} = read_program_loop(state, [], true)
    state = expect_sym(state, :rparen)
    state = %{state | mode: old_mode}
    {nodes, state}
  end

  # ------------------------------------------------------------------
  # define X as C   |   define X grouping_expr
  # ------------------------------------------------------------------

  defp read_define(state, line) do
    case peek(state) do
      {:name, name, _} ->
        state = advance(state)
        read_define_body(state, name, line)

      tok ->
        state = add_error(state, "expected name after 'define'", tok_line(tok))
        {nil, state}
    end
  end

  defp read_define_body(state, name, line) do
    case peek(state) do
      {:keyword, :as, _} ->
        state = advance(state)
        {body, state} = read_C(state)
        # Support top-level or/and chaining without wrapping parens.
        {body, state} = apply_combinators(state, body, line)
        # Record that this routine is in the symbol table (if it was pre-declared).
        state = mark_routine_mode(state, name, state.mode, line)
        node = %{kind: :define_routine, name: name, body: body, line: line}
        {node, state}

      _ ->
        # Grouping definition: define NAME string_expr
        # Auto-declare the grouping in the symbol table if not already there.
        state =
          if Map.has_key?(state.symbols, name) do
            state
          else
            declare(state, name, :grouping, line)
          end

        {strings, state} = read_grouping_expr(state)
        node = %{kind: :define_grouping, name: name, strings: strings, line: line}
        {node, state}
    end
  end

  defp mark_routine_mode(state, name, mode, line) do
    case Map.get(state.symbols, name) do
      nil ->
        # Implicitly declared (no prior routines/externals declaration).
        declare(state, name, :routine, line)

      %{mode: :unknown} = sym ->
        %{state | symbols: Map.put(state.symbols, name, %{sym | mode: mode})}

      %{mode: ^mode} ->
        state

      %{mode: other} ->
        add_error(state, "'#{name}' defined in both #{other} and #{mode} mode", line)
    end
  end

  # ------------------------------------------------------------------
  # Grouping expression: 'string' (+ 'string' | + grouping_name)*
  # ------------------------------------------------------------------

  defp read_grouping_expr(state) do
    read_grouping_parts(state, [])
  end

  defp read_grouping_parts(state, acc) do
    {part, state} = read_grouping_atom(state)
    read_grouping_ops(state, acc ++ part)
  end

  # After reading an atom, consume any chain of +/- operations without
  # reading another unconditional atom first.
  defp read_grouping_ops(state, acc) do
    case peek(state) do
      {:sym, :plus, _} ->
        {part, state} = read_grouping_atom(advance(state))
        read_grouping_ops(state, acc ++ part)

      {:sym, :minus, _} ->
        {part, state} = read_grouping_atom(advance(state))
        minus_items = Enum.map(part, fn
          {:grouping_ref, name} -> {:grouping_minus_ref, name}
          cp when is_binary(cp) -> {:grouping_minus_cp, cp}
        end)
        read_grouping_ops(state, acc ++ minus_items)

      _ ->
        {acc, state}
    end
  end

  defp read_grouping_atom(state) do
    case peek(state) do
      {:string, s, _} ->
        codepoints = s |> String.graphemes()
        {codepoints, advance(state)}

      {:name, name, line} ->
        # A reference to another grouping — expand inline.
        {state, _} = resolve(advance(state), name, :grouping, line)
        # We don't expand at this point; leave as a reference.
        # The generator resolves grouping references at compile time.
        {[{:grouping_ref, name}], state}

      tok ->
        state = add_error(state, "expected string or grouping name in grouping definition", tok_line(tok))
        {[], state}
    end
  end

  # ------------------------------------------------------------------
  # Command parser — read_C
  # ------------------------------------------------------------------

  defp read_C(state) do
    line = current_line(state)

    case peek(state) do
      {:sym, :lparen, _} ->
        state = advance(state)
        read_C_list(state, line)

      {:keyword, :backwards, _} ->
        old_mode = state.mode
        state = %{advance(state) | mode: :backward}
        {body, state} = read_C(state)
        state = %{state | mode: old_mode}
        {%{kind: :backwards, body: body, line: line}, state}

      {:keyword, :reverse, _} ->
        old_mode = state.mode
        new_mode = if old_mode == :forward, do: :backward, else: :forward
        state = %{advance(state) | mode: new_mode}
        {body, state} = read_C(state)
        state = %{state | mode: old_mode}
        {%{kind: :reverse, body: body, line: line}, state}

      {:keyword, :not, _} ->
        {body, state} = read_C(advance(state))
        {%{kind: :not, body: body, line: line}, state}

      {:keyword, :try, _} ->
        {body, state} = read_C(advance(state))
        {%{kind: :try, body: body, line: line}, state}

      {:keyword, :test, _} ->
        {body, state} = read_C(advance(state))
        # `test substring among(...)` is a special compound form: the among
        # runs with the cursor saved/restored around the search, and the
        # action dispatch runs with the restored cursor. Combine them into a
        # single :test_among node so the generator can emit the right code.
        case body do
          %{kind: :substring} ->
            case peek(state) do
              {:keyword, :among, _} ->
                {among, state} = read_C(state)
                {%{kind: :test_among, among: among, line: line}, state}
              _ ->
                {%{kind: :test, body: body, line: line}, state}
            end
          _ ->
            {%{kind: :test, body: body, line: line}, state}
        end

      {:keyword, :do, _} ->
        {body, state} = read_C(advance(state))
        {%{kind: :do, body: body, line: line}, state}

      {:keyword, :fail, _} ->
        {body, state} = read_C(advance(state))
        {%{kind: :fail, body: body, line: line}, state}

      {:keyword, :repeat, _} ->
        {body, state} = read_C(advance(state))
        {%{kind: :repeat, body: body, line: line}, state}

      {:keyword, :goto, _} ->
        {body, state} = read_C(advance(state))
        {make_goto(:goto, body, line), state}

      {:keyword, :gopast, _} ->
        {body, state} = read_C(advance(state))
        {make_goto(:gopast, body, line), state}

      {:keyword, :loop, _} ->
        {count, state} = read_AE(advance(state))
        {body, state} = read_C(state)
        {%{kind: :loop, count: count, body: body, line: line}, state}

      {:keyword, :atleast, _} ->
        {count, state} = read_AE(advance(state))
        {body, state} = read_C(state)
        {%{kind: :atleast, count: count, body: body, line: line}, state}

      {:keyword, :set, _} ->
        case peek(advance(state)) do
          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :boolean, nline)
            {%{kind: :set, var: name, line: line}, state}
          tok ->
            state = add_error(advance(state), "expected boolean name after 'set'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:keyword, :unset, _} ->
        case peek(advance(state)) do
          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :boolean, nline)
            {%{kind: :unset, var: name, line: line}, state}
          tok ->
            state = add_error(advance(state), "expected boolean name after 'unset'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:keyword, :setmark, _} ->
        case peek(advance(state)) do
          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :integer, nline)
            {%{kind: :setmark, var: name, line: line}, state}
          tok ->
            state = add_error(advance(state), "expected integer name after 'setmark'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:keyword, :tomark, _} ->
        {ae, state} = read_AE(advance(state))
        {%{kind: :tomark, ae: ae, line: line}, state}

      {:keyword, :atmark, _} ->
        {ae, state} = read_AE(advance(state))
        {%{kind: :atmark, ae: ae, line: line}, state}

      {:keyword, :tolimit, _} ->
        {%{kind: :tolimit, line: line}, advance(state)}

      {:keyword, :atlimit, _} ->
        {%{kind: :atlimit, line: line}, advance(state)}

      {:keyword, :hop, _} ->
        {ae, state} = read_AE(advance(state))
        {%{kind: :hop, count: ae, line: line}, state}

      {:keyword, :next, _} ->
        {%{kind: :next, line: line}, advance(state)}

      {:keyword, :delete, _} ->
        {%{kind: :delete, line: line}, advance(state)}

      {:keyword, :true, _} ->
        {%{kind: :true, line: line}, advance(state)}

      {:keyword, :false, _} ->
        {%{kind: :false, line: line}, advance(state)}

      {:keyword, :insert, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :insert, arg: str_node, line: line}, state}

      {:keyword, :attach, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :attach, arg: str_node, line: line}, state}

      {:keyword, :substring, _} ->
        {%{kind: :substring, line: line}, advance(state)}

      {:keyword, :among, _} ->
        {entries, pre_constraint, default_action, state} = read_among(advance(state))
        {%{kind: :among, entries: entries, pre_constraint: pre_constraint, default_action: default_action, line: line}, state}

      {:keyword, :setlimit, _} ->
        {limit_cmd, state} = read_C(advance(state))
        state = expect_keyword(state, :for)
        {body, state} = read_C(state)
        {%{kind: :setlimit, limit_cmd: limit_cmd, body: body, line: line}, state}

      {:keyword, :non, _} ->
        case peek(advance(state)) do
          {:sym, :minus, _} ->
            # non-name (written with a hyphen as suffix in the grammar docs)
            state = advance(advance(state))
            case peek(state) do
              {:name, name, nline} ->
                {state, _} = resolve(advance(state), name, :grouping, nline)
                {%{kind: :out_grouping, grouping: name, line: line}, state}
              tok ->
                state = add_error(state, "expected grouping name after 'non-'", tok_line(tok))
                {%{kind: :true, line: line}, state}
            end

          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :grouping, nline)
            {%{kind: :out_grouping, grouping: name, line: line}, state}

          tok ->
            state = add_error(advance(state), "expected grouping name after 'non'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:sym, :lbracket, _} ->
        {%{kind: :leftslice, line: line}, advance(state)}

      {:sym, :rbracket, _} ->
        {%{kind: :rightslice, line: line}, advance(state)}

      {:sym, :slice_from, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :slicefrom, arg: str_node, line: line}, state}

      {:sym, :insert_sym, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :insert, arg: str_node, line: line}, state}

      {:sym, :slice_to, _} ->
        case peek(advance(state)) do
          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :string, nline)
            {%{kind: :sliceto, var: name, line: line}, state}
          tok ->
            state = add_error(advance(state), "expected string variable after '->'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:sym, :assign_to, _} ->
        case peek(advance(state)) do
          {:name, name, nline} ->
            {state, _} = resolve(advance(advance(state)), name, :string, nline)
            {%{kind: :assign_to, var: name, line: line}, state}
          tok ->
            state = add_error(advance(state), "expected string variable after '=>'", tok_line(tok))
            {%{kind: :true, line: line}, state}
        end

      {:sym, :assign, _} ->
        # = 'string'  (string assignment to current)
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :string_assign, arg: str_node, line: line}, state}

      {:sym, :dollar, _} ->
        read_dollar(advance(state), line)

      {:string, s, _} ->
        {%{kind: :eq_s, string: s, line: line}, advance(state)}

      {:name, name, _} ->
        read_name_command(advance(state), name, line)

      {:keyword, :cursor, _} ->
        # `cursor` as a command is `atmark cursor` which is always true,
        # but as a standalone name it's the cursor variable in AE context.
        # As a command it doesn't make sense alone; treat as a call.
        {%{kind: :cursor_cmd, line: line}, advance(state)}

      {:keyword, :limit, _} ->
        {%{kind: :limit_cmd, line: line}, advance(state)}

      {:keyword, :get, _} ->
        # get is rarely used (gets a string from outside) — treat as no-op here
        case peek(advance(state)) do
          {:name, name, _nline} -> {%{kind: :get, var: name, line: line}, advance(advance(state))}
          _ -> {%{kind: :true, line: line}, advance(state)}
        end

      tok ->
        state = add_error(state, "unexpected token '#{format_tok(tok)}' in command", tok_line(tok))
        {%{kind: :true, line: line}, if(tok, do: advance(state), else: state)}
    end
  end

  # ------------------------------------------------------------------
  # Command list: (C ('or' | 'and')? C ...)*  ending at ')'
  # ------------------------------------------------------------------

  defp read_C_list(state, line) do
    read_C_list_loop(state, [], line)
  end

  defp read_C_list_loop(state, acc, line) do
    case peek(state) do
      {:sym, :rparen, _} ->
        body = flatten_seq(Enum.reverse(acc))
        {body, advance(state)}

      nil ->
        state = add_error(state, "unexpected end of input, expected ')'", 0)
        {flatten_seq(Enum.reverse(acc)), state}

      _ ->
        {cmd, state} = read_C(state)
        # Check for 'or'/'and' combinators. After each chain,
        # check for the opposite combinator (lower precedence).
        {cmd, state} = apply_combinators(state, cmd, line)
        read_C_list_loop(state, [cmd | acc], line)
    end
  end

  # Consume a sequence of or/and combinators after a single command has been
  # read.  'and' binds tighter than 'or', so 'C1 and C2 or C3' is
  # '(C1 and C2) or C3'.
  defp apply_combinators(state, node, line) do
    case peek(state) do
      {:keyword, :and, _} ->
        {node, state} = read_and_chain(state, node, line)
        apply_combinators(state, node, line)

      {:keyword, :or, _} ->
        {node, state} = read_or_chain(state, node, line)
        apply_combinators(state, node, line)

      _ ->
        {node, state}
    end
  end

  defp read_or_chain(state, first, line) do
    {_, state} = consume(state)  # consume 'or'
    {second, state} = read_C(state)
    node = %{kind: :or, left: first, right: second, line: line}
    case peek(state) do
      {:keyword, :or, _} -> read_or_chain(state, node, line)
      _ -> {node, state}
    end
  end

  defp read_and_chain(state, first, line) do
    {_, state} = consume(state)  # consume 'and'
    {second, state} = read_C(state)
    node = %{kind: :and, left: first, right: second, line: line}
    case peek(state) do
      {:keyword, :and, _} -> read_and_chain(state, node, line)
      _ -> {node, state}
    end
  end

  # Flatten a single-item seq into the item itself.
  defp flatten_seq([single]), do: single

  defp flatten_seq(cmds) do
    %{kind: :seq, body: transform_slice_among(cmds), line: 0}
  end

  # Detect the `[substring] restriction... among(...)` pattern in a seq and
  # combine it into a single `:slice_among` node so the generator can emit
  # the correct code order: ket, find_among, bra, restriction, switch.
  #
  # Also handles `[substring] restriction... (among(...) or C)` and the `and`
  # variant, where the among is the left branch of an :or / :and combinator.
  # In that case the slice_among replaces the among inside the combinator.
  #
  # Also handles `setlimit LIMIT for ([substring]) restriction... among(...)`,
  # which the Snowball C compiler fuses into a single limit-aware search.
  defp transform_slice_among(cmds) do
    case split_at_slice_among(cmds) do
      nil ->
        case split_at_wrapped_slice_among(cmds) do
          nil ->
            case split_at_setlimit_slice_among(cmds) do
              nil ->
                case split_at_bare_substring_among(cmds) do
                  nil ->
                    cmds

                  {before, restrictions, among_node, after_cmds} ->
                    # `substring restriction... among(...)` — bare `substring`
                    # (no enclosing `[` / `]`).  The Snowball C compiler emits
                    # find_among THEN the restriction check, so the restriction
                    # is applied with the post-match cursor position.  We model
                    # this as a :restricted_among node so the generator can
                    # emit the correct order.
                    restricted_among = %{
                      kind: :restricted_among,
                      among: among_node,
                      restrictions: restrictions,
                      line: among_node.line
                    }

                    transform_slice_among(
                      before ++ [restricted_among | transform_slice_among(after_cmds)]
                    )
                end

              {before, limit_cmd, restrictions, among_node, after_cmds} ->
                setlimit_slice_among = %{
                  kind: :setlimit_slice_among,
                  limit_cmd: limit_cmd,
                  among: among_node,
                  restrictions: restrictions,
                  line: among_node.line
                }

                transform_slice_among(
                  before ++ [setlimit_slice_among | transform_slice_among(after_cmds)]
                )
            end

          {before, restrictions, wrap_fn, among_node, after_cmds} ->
            slice_among = %{
              kind: :slice_among,
              among: among_node,
              restrictions: restrictions,
              line: among_node.line
            }

            transform_slice_among(before ++ [wrap_fn.(slice_among) | transform_slice_among(after_cmds)])
        end

      {before, restrictions, among_node, after_cmds} ->
        slice_among = %{
          kind: :slice_among,
          among: among_node,
          restrictions: restrictions,
          line: among_node.line
        }

        transform_slice_among(before ++ [slice_among | transform_slice_among(after_cmds)])
    end
  end

  # Look for `setlimit(LIMIT, leftslice+substring body) restriction... among`
  # at any position in the command list.  The Snowball C compiler fuses this
  # into: ket=cursor, set-limit, find_among, bra=cursor (after), restore-limit.
  defp split_at_setlimit_slice_among([]) do
    nil
  end

  defp split_at_setlimit_slice_among([
         %{kind: :setlimit, limit_cmd: limit_cmd, body: body}
         | rest
       ]) do
    if setlimit_body_has_leftslice?(body) do
      case Enum.split_while(rest, fn c -> c.kind != :among end) do
        {restrictions, [among_node | after_cmds]} ->
          {[], limit_cmd, restrictions, among_node, after_cmds}

        {_, []} ->
          nil
      end
    else
      case split_at_setlimit_slice_among(rest) do
        nil ->
          nil

        {before, limit_cmd2, restrictions, among_node, after_cmds} ->
          {[%{kind: :setlimit, limit_cmd: limit_cmd, body: body} | before], limit_cmd2,
           restrictions, among_node, after_cmds}
      end
    end
  end

  defp split_at_setlimit_slice_among([first | rest]) do
    case split_at_setlimit_slice_among(rest) do
      nil ->
        nil

      {before, limit_cmd, restrictions, among_node, after_cmds} ->
        {[first | before], limit_cmd, restrictions, among_node, after_cmds}
    end
  end

  # A setlimit body qualifies for the setlimit_slice_among fusion only when it
  # is (or contains as a seq) BOTH a leftslice and a substring node — i.e. the
  # canonical `[substring] among(...)` pattern.  Plain literal-match bodies
  # like `['t'] test V1 delete` must NOT be fused: they have a leftslice but
  # no substring, so the adjacent `among(...)` belongs to a later setlimit.
  defp setlimit_body_has_leftslice?(%{kind: :seq, body: children}) do
    Enum.any?(children, fn c -> c.kind == :leftslice end) and
      Enum.any?(children, fn c -> c.kind == :substring end)
  end

  defp setlimit_body_has_leftslice?(%{kind: :leftslice}), do: false
  defp setlimit_body_has_leftslice?(_), do: false

  # Look for `[leftslice, substring, rightslice, restriction..., among]`
  # at any position in the command list.
  defp split_at_slice_among([]) do
    nil
  end

  defp split_at_slice_among([
         %{kind: :leftslice},
         %{kind: :substring},
         %{kind: :rightslice}
         | rest
       ]) do
    pred = fn c ->
      case c do
        %{kind: :among} -> false
        %{kind: :seq, body: [%{kind: :among} | _]} -> false
        _ -> true
      end
    end

    case Enum.split_while(rest, pred) do
      {restrictions, [%{kind: :among} = among_node | after_cmds]} ->
        {[], restrictions, among_node, after_cmds}

      {restrictions, [%{kind: :seq, body: [%{kind: :among} = among_node | extra]} | after_cmds]} ->
        extra_cmds =
          if extra == [],
            do: after_cmds,
            else: [%{kind: :seq, body: extra, line: 0} | after_cmds]

        {[], restrictions, among_node, extra_cmds}

      {_, []} ->
        nil
    end
  end

  defp split_at_slice_among([first | rest]) do
    case split_at_slice_among(rest) do
      nil -> nil
      {before, restrictions, among_node, after_cmds} -> {[first | before], restrictions, among_node, after_cmds}
    end
  end

  # Look for `[leftslice, substring, rightslice, restriction..., (among or C)]`
  # where the among is the LEFT branch of an :or or :and combinator node.
  # Returns `{before, restrictions, wrap_fn, among_node, after_cmds}` where
  # `wrap_fn` rebuilds the combinator around the (now slice_among) node.
  defp split_at_wrapped_slice_among([]) do
    nil
  end

  defp split_at_wrapped_slice_among([
         %{kind: :leftslice},
         %{kind: :substring},
         %{kind: :rightslice}
         | rest
       ]) do
    pred = fn c ->
      case c do
        %{kind: kind, left: %{kind: :among}} when kind in [:or, :and] -> false
        _ -> true
      end
    end

    case Enum.split_while(rest, pred) do
      {restrictions, [%{kind: kind, left: %{kind: :among} = among_node} = wrapper | after_cmds]}
      when kind in [:or, :and] ->
        wrap_fn = fn slice_among -> %{wrapper | left: slice_among} end
        {[], restrictions, wrap_fn, among_node, after_cmds}

      _ ->
        nil
    end
  end

  defp split_at_wrapped_slice_among([first | rest]) do
    case split_at_wrapped_slice_among(rest) do
      nil ->
        nil

      {before, restrictions, wrap_fn, among_node, after_cmds} ->
        {[first | before], restrictions, wrap_fn, among_node, after_cmds}
    end
  end

  # Look for `[substring, restriction..., among]` — bare `substring` (not
  # preceded by `[`) followed by optional restriction nodes and then an among.
  # The Snowball C compiler emits find_among FIRST and the restriction AFTER
  # (post-match check), which is the opposite of the left-to-right seq order.
  # Returns `{before, restrictions, among_node, after_cmds}`.
  defp split_at_bare_substring_among([]) do
    nil
  end

  defp split_at_bare_substring_among([%{kind: :substring} | rest]) do
    pred = fn c ->
      case c do
        %{kind: :among} -> false
        _ -> true
      end
    end

    case Enum.split_while(rest, pred) do
      {restrictions, [%{kind: :among} = among_node | after_cmds]} ->
        {[], restrictions, among_node, after_cmds}

      {_, []} ->
        nil
    end
  end

  defp split_at_bare_substring_among([first | rest]) do
    # Only look for bare substring at positions where it is NOT immediately
    # preceded by a leftslice (that case is handled by split_at_slice_among).
    case split_at_bare_substring_among(rest) do
      nil ->
        nil

      {before, restrictions, among_node, after_cmds} ->
        {[first | before], restrictions, among_node, after_cmds}
    end
  end

  # ------------------------------------------------------------------
  # Name reference — call, boolean test, or grouping test
  # ------------------------------------------------------------------

  defp read_name_command(state, name, line) do
    case Map.get(state.symbols, name) do
      %{type: :routine} ->
        {%{kind: :call, routine: name, line: line}, state}

      %{type: :external} ->
        {%{kind: :call, routine: name, line: line}, state}

      %{type: :boolean} ->
        {%{kind: :booltest, var: name, line: line}, state}

      %{type: :grouping} ->
        {%{kind: :in_grouping, grouping: name, line: line}, state}

      %{type: :string} ->
        # String variable used as a command — matches the next N chars against
        # the string's current value (equivalent to eq_s_var in the runtime).
        {%{kind: :eq_s_var, var: name, line: line}, state}

      nil ->
        state = add_error(state, "'#{name}' undeclared", line)
        {%{kind: :true, line: line}, state}

      %{type: other} ->
        state = add_error(state, "'#{name}' has type #{other}, not callable", line)
        {%{kind: :true, line: line}, state}
    end
  end

  # ------------------------------------------------------------------
  # goto / gopast optimisation — merge with grouping/non-grouping
  # ------------------------------------------------------------------

  defp make_goto(goto_or_gopast, %{kind: :in_grouping} = body, line) do
    kind = if goto_or_gopast == :goto, do: :goto_grouping, else: :gopast_grouping
    %{kind: kind, grouping: body.grouping, line: line}
  end

  defp make_goto(goto_or_gopast, %{kind: :out_grouping} = body, line) do
    kind = if goto_or_gopast == :goto, do: :goto_non, else: :gopast_non
    %{kind: kind, grouping: body.grouping, line: line}
  end

  defp make_goto(goto_or_gopast, body, line) do
    %{kind: goto_or_gopast, body: body, line: line}
  end

  # ------------------------------------------------------------------
  # $ — integer operation  ($name op AE  or  $(AE op AE))
  # ------------------------------------------------------------------

  defp read_dollar(state, line) do
    case peek(state) do
      {:sym, :lparen, _} ->
        # $(AE op AE)
        state = advance(state)
        {lhs, state} = read_AE(state)
        {op, state} = read_rel_op(state)
        {rhs, state} = read_AE(state)
        state = expect_sym(state, :rparen)
        {%{kind: :int_test, lhs: lhs, op: op, rhs: rhs, line: line}, state}

      {:name, name, nline} ->
        {state, _} = resolve(advance(state), name, :integer, nline)
        {op, state} = read_assign_or_rel_op(state, line)
        {rhs, state} = read_AE(state)
        {%{kind: :dollar, var: name, op: op, rhs: rhs, line: line}, state}

      tok ->
        state = add_error(state, "expected name or '(' after '$'", tok_line(tok))
        {%{kind: :true, line: line}, state}
    end
  end

  defp read_rel_op(state) do
    case peek(state) do
      {:sym, op, _} when op in [:eq, :ne, :lt, :le, :gt, :ge] ->
        {op, advance(state)}

      tok ->
        state = add_error(state, "expected relational operator", tok_line(tok))
        {:eq, state}
    end
  end

  defp read_assign_or_rel_op(state, line) do
    case peek(state) do
      {:sym, op, _}
      when op in [:assign, :plus_assign, :minus_assign, :multiply_assign, :divide_assign,
                  :eq, :ne, :lt, :le, :gt, :ge] ->
        {op, advance(state)}

      tok ->
        state = add_error(state, "expected operator after variable in '$' expression", tok_line(tok))
        {:assign, add_error(state, "expected operator", line)}
    end
  end

  # ------------------------------------------------------------------
  # String argument (after <-, insert, attach, =)
  # ------------------------------------------------------------------

  defp read_string_arg(state) do
    case peek(state) do
      {:string, s, _} ->
        {{:literal, s}, advance(state)}

      {:name, name, line} ->
        {state, _} = resolve(advance(state), name, :string, line)
        {{:var, name}, state}

      tok ->
        state = add_error(state, "expected string literal or string variable", tok_line(tok))
        {{:literal, ""}, state}
    end
  end

  # ------------------------------------------------------------------
  # Integer arithmetic expression parser
  # ------------------------------------------------------------------

  defp read_AE(state) do
    read_AE_prec(state, 0)
  end

  defp read_AE_prec(state, min_prec) do
    line = current_line(state)
    {lhs, state} = read_AE_atom(state, line)
    read_AE_binop(state, lhs, min_prec)
  end

  defp read_AE_atom(state, line) do
    case peek(state) do
      {:sym, :minus, _} ->
        {operand, state} = read_AE_prec(advance(state), 100)
        {%{kind: :neg, operand: operand, line: line}, state}

      {:sym, :lparen, _} ->
        state = advance(state)
        {inner, state} = read_AE_prec(state, 0)
        state = expect_sym(state, :rparen)
        {inner, state}

      {:integer, n, _} ->
        {%{kind: :integer_literal, value: n, line: line}, advance(state)}

      {:keyword, :cursor, _} ->
        {%{kind: :cursor_ref, line: line}, advance(state)}

      {:keyword, :limit, _} ->
        {%{kind: :limit_ref, line: line}, advance(state)}

      {:keyword, :len, _} ->
        {%{kind: :len_ref, line: line}, advance(state)}

      {:keyword, :size, _} ->
        {%{kind: :size_ref, line: line}, advance(state)}

      {:keyword, :maxint, _} ->
        {%{kind: :maxint_ref, line: line}, advance(state)}

      {:keyword, :minint, _} ->
        {%{kind: :minint_ref, line: line}, advance(state)}

      {:keyword, :lenof, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :lenof, arg: str_node, line: line}, state}

      {:keyword, :sizeof, _} ->
        {str_node, state} = read_string_arg(advance(state))
        {%{kind: :sizeof, arg: str_node, line: line}, state}

      {:name, name, nline} ->
        {state, _} = resolve(advance(state), name, :integer, nline)
        {%{kind: :var_ref, var: name, line: nline}, state}

      tok ->
        state = add_error(state, "expected integer expression", tok_line(tok))
        {%{kind: :integer_literal, value: 0, line: line}, state}
    end
  end

  @ae_prec %{plus: 1, minus: 1, multiply: 2, divide: 2}

  defp read_AE_binop(state, lhs, min_prec) do
    case peek(state) do
      {:sym, op, _} ->
        case Map.get(@ae_prec, op) do
          nil ->
            {lhs, state}

          prec when prec > min_prec ->
            line = current_line(state)
            {rhs, state} = read_AE_prec(advance(state), prec)
            node = %{kind: op, left: lhs, right: rhs, line: line}
            read_AE_binop(state, node, min_prec)

          _ ->
            {lhs, state}
        end

      _ ->
        {lhs, state}
    end
  end

  # ------------------------------------------------------------------
  # among ( entries )
  #
  # Entry format in source:
  #   'str1' 'str2' ... (action)
  #
  # We collect them as {strings, action_node | nil} groups.
  # ------------------------------------------------------------------

  defp read_among(state) do
    state = expect_sym(state, :lparen)
    {entries, pre_constraint, default_action, state} = read_among_loop(state, [], [], nil, nil)
    {entries, pre_constraint, default_action, state}
  end

  # pre_constraint: a bare action block that appears BEFORE any strings, e.g.
  #   `among( (RV) 'ando' 'endo' (delete) ... )`  in Italian.
  #   The Snowball C compiler emits this as a universal post-match check
  #   (applied after find_among but before the case dispatch).
  #
  # `current_entries` is a list of `{string, constraint_routine | nil}` pairs.
  # Bare routine names (e.g. `R1` in `'a' R1 'o' R1 (delete)`) are stored as
  # per-entry constraints that are encoded as closure functions in the among
  # table's 4th parameter slot.  They are NOT flushed as stand-alone actions —
  # accumulation continues until an explicit action block `(...)` is seen.
  # This matches the canonical Snowball C compiler behaviour where per-entry
  # constraint functions and the associated action are entirely orthogonal.
  defp read_among_loop(state, current_entries, acc, pre_constraint, _default_action) do
    case peek(state) do
      {:sym, :rparen, _} ->
        entries = flush_among_group(current_entries, nil, acc)
        {Enum.reverse(entries), pre_constraint, nil, advance(state)}

      {:string, s, _} ->
        read_among_loop(advance(state), current_entries ++ [{s, nil}], acc, pre_constraint, nil)

      {:sym, :lparen, _} ->
        # Action block
        line = current_line(state)
        state = advance(state)
        {action, state} = read_among_action(state, line)

        if current_entries == [] do
          if acc == [] do
            # Leading bare action before any strings: a pre-constraint that the
            # Snowball compiler applies universally after find_among succeeds but
            # before the case dispatch (e.g. Italian's `(RV)` in
            # `among( (RV) 'ando' 'endo' (delete) ... )`).
            read_among_loop(state, [], acc, action, nil)
          else
            # Trailing bare action with no pending strings — should not happen
            # with well-formed Snowball source.  Treat conservatively as a
            # no-op continuation (don't set default_action).
            read_among_loop(state, [], acc, pre_constraint, nil)
          end
        else
          acc = flush_among_group(current_entries, action, acc)
          read_among_loop(state, [], acc, pre_constraint, nil)
        end

      {:name, name, line} ->
        # Bare routine reference in among context: stored as a per-entry
        # constraint function in the among table's 4th-parameter slot.  It
        # applies to the immediately preceding string; accumulation of further
        # strings then continues uninterrupted so that the following action
        # block (e.g. `(delete)`) becomes the shared action for the whole group.
        {state, _} = resolve(advance(state), name, :routine, line)

        updated_entries =
          case current_entries do
            [] ->
              # No preceding string — ignore the dangling routine name.
              []

            entries ->
              # Attach the constraint to the last accumulated string.
              {preceding, [{last_str, _old_constraint}]} =
                Enum.split(entries, length(entries) - 1)

              preceding ++ [{last_str, name}]
          end

        read_among_loop(state, updated_entries, acc, pre_constraint, nil)

      nil ->
        state = add_error(state, "unexpected end of input in among", 0)
        {Enum.reverse(acc), pre_constraint, nil, state}

      tok ->
        state = add_error(state, "unexpected token '#{format_tok(tok)}' in among", tok_line(tok))
        {Enum.reverse(acc), pre_constraint, nil, advance(state)}
    end
  end

  defp read_among_action(state, line) do
    # An action block is a C_list (same as a parenthesised command list)
    # but already past the opening '('.
    read_C_list(state, line)
  end

  # Flush accumulated `{string, constraint | nil}` pairs as a single group.
  # If every constraint is nil we omit the `constraints` field for compactness.
  defp flush_among_group([], _action, acc), do: acc

  defp flush_among_group(entries, action, acc) do
    strings = Enum.map(entries, fn {s, _c} -> s end)
    constraints = Enum.map(entries, fn {_s, c} -> c end)

    group =
      if Enum.all?(constraints, &is_nil/1) do
        %{strings: strings, action: action}
      else
        %{strings: strings, action: action, constraints: constraints}
      end

    [group | acc]
  end

  # ------------------------------------------------------------------
  # Formatting helpers
  # ------------------------------------------------------------------

  defp format_tok(nil), do: "end of input"
  defp format_tok({:keyword, atom, _}), do: to_string(atom)
  defp format_tok({:sym, atom, _}), do: to_string(atom)
  defp format_tok({:name, s, _}), do: s
  defp format_tok({:integer, n, _}), do: to_string(n)
  defp format_tok({:string, s, _}), do: "'#{s}'"
end
