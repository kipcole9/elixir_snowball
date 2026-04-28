defmodule Snowball.AnalyserTest do
  use ExUnit.Case, async: true
  doctest Snowball.Analyser

  alias Snowball.{Lexer, Analyser}

  defp parse!(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, program} = Analyser.analyse(tokens)
    program
  end

  defp parse_err(source) do
    {:ok, tokens} = Lexer.tokenize(source)
    Analyser.analyse(tokens)
  end

  # ------------------------------------------------------------------
  # Top-level structure
  # ------------------------------------------------------------------

  test "empty source produces empty program" do
    prog = parse!("")
    assert prog.kind == :program
    assert prog.defs == []
    assert prog.symbols == %{}
  end

  test "integer declaration adds to symbol table" do
    prog = parse!("integers ( p1 p2 )")
    assert %{type: :integer} = prog.symbols["p1"]
    assert %{type: :integer} = prog.symbols["p2"]
  end

  test "boolean declaration adds to symbol table" do
    prog = parse!("booleans ( Y_found )")
    assert %{type: :boolean} = prog.symbols["Y_found"]
  end

  test "routines declaration adds to symbol table" do
    prog = parse!("routines ( stem_1 stem_2 )")
    assert %{type: :routine} = prog.symbols["stem_1"]
    assert %{type: :routine} = prog.symbols["stem_2"]
  end

  test "externals declaration adds to symbol table" do
    prog = parse!("externals ( stem )")
    assert %{type: :external} = prog.symbols["stem"]
  end

  test "groupings declaration adds to symbol table" do
    prog = parse!("groupings ( v v_WXY )")
    assert %{type: :grouping} = prog.symbols["v"]
    assert %{type: :grouping} = prog.symbols["v_WXY"]
  end

  test "stringescapes directive is accepted" do
    prog = parse!("stringescapes {}")
    assert prog.defs == []
  end

  # ------------------------------------------------------------------
  # Routine definitions
  # ------------------------------------------------------------------

  test "define routine with simple body" do
    prog = parse!("routines ( r ) define r as ( delete )")
    assert [%{kind: :define_routine, name: "r"}] = prog.defs
  end

  test "define routine body is parsed as command" do
    prog = parse!("routines ( r ) define r as delete")
    [%{kind: :define_routine, body: body}] = prog.defs
    assert body.kind == :delete
  end

  test "define sequence of commands" do
    prog = parse!("routines ( r ) define r as (delete next)")
    [%{kind: :define_routine, body: %{kind: :seq, body: cmds}}] = prog.defs
    assert length(cmds) == 2
    assert Enum.at(cmds, 0).kind == :delete
    assert Enum.at(cmds, 1).kind == :next
  end

  # ------------------------------------------------------------------
  # Grouping definitions
  # ------------------------------------------------------------------

  test "define grouping with literal string" do
    prog = parse!("groupings ( v ) define v 'aeiouy'")
    [%{kind: :define_grouping, name: "v", strings: strings}] = prog.defs
    # Each codepoint is a grapheme in the list
    assert "a" in strings
    assert "e" in strings
    assert "y" in strings
  end

  test "define grouping with concatenation" do
    prog = parse!("groupings ( v g ) define v 'aeiou' define g 'xy'")
    [%{kind: :define_grouping, name: "v"}, %{kind: :define_grouping, name: "g"}] = prog.defs
  end

  # ------------------------------------------------------------------
  # Commands
  # ------------------------------------------------------------------

  test "do command" do
    prog = parse!("routines ( r ) define r as do delete")
    [%{body: %{kind: :do, body: inner}}] = prog.defs
    assert inner.kind == :delete
  end

  test "try command" do
    prog = parse!("routines ( r ) define r as try delete")
    [%{body: %{kind: :try}}] = prog.defs
  end

  test "not command" do
    prog = parse!("routines ( r ) define r as not atlimit")
    [%{body: %{kind: :not}}] = prog.defs
  end

  test "repeat command" do
    prog = parse!("routines ( r ) define r as repeat next")
    [%{body: %{kind: :repeat}}] = prog.defs
  end

  test "goto command" do
    prog = parse!("routines ( r ) define r as goto next")
    [%{body: %{kind: :goto}}] = prog.defs
  end

  test "gopast command" do
    prog = parse!("routines ( r ) define r as gopast next")
    [%{body: %{kind: :gopast}}] = prog.defs
  end

  test "backwards command" do
    prog = parse!("routines ( r ) define r as backwards delete")
    [%{body: %{kind: :backwards}}] = prog.defs
  end

  test "set and unset boolean" do
    prog = parse!("booleans ( found ) routines ( r ) define r as ( set found unset found )")
    [%{body: %{kind: :seq, body: [s, u]}}] = prog.defs
    assert s == %{kind: :set, var: "found", line: s.line}
    assert u == %{kind: :unset, var: "found", line: u.line}
  end

  test "slice markers" do
    prog = parse!("routines ( r ) define r as ( [ ] )")
    [%{body: %{kind: :seq, body: [ls, rs]}}] = prog.defs
    assert ls.kind == :leftslice
    assert rs.kind == :rightslice
  end

  test "slicefrom" do
    prog = parse!("routines ( r ) define r as <- 'ee'")
    [%{body: %{kind: :slicefrom, arg: {:literal, "ee"}}}] = prog.defs
  end

  test "delete" do
    prog = parse!("routines ( r ) define r as delete")
    [%{body: %{kind: :delete}}] = prog.defs
  end

  test "true and false" do
    prog = parse!("routines ( r ) define r as ( true false )")
    [%{body: %{kind: :seq, body: [t, f]}}] = prog.defs
    assert t.kind == :true
    assert f.kind == :false
  end

  test "atlimit and tolimit" do
    prog = parse!("routines ( r ) define r as ( atlimit tolimit )")
    [%{body: %{kind: :seq, body: [al, tl]}}] = prog.defs
    assert al.kind == :atlimit
    assert tl.kind == :tolimit
  end

  test "literal string as eq_s command" do
    prog = parse!("routines ( r ) define r as 'ing'")
    [%{body: %{kind: :eq_s, string: "ing"}}] = prog.defs
  end

  test "or combinator" do
    prog = parse!("routines ( r ) define r as ( true or false )")
    [%{body: %{kind: :or}}] = prog.defs
  end

  test "and combinator" do
    prog = parse!("routines ( r ) define r as ( atlimit and next )")
    [%{body: %{kind: :and}}] = prog.defs
  end

  test "loop command" do
    prog = parse!("routines ( r ) define r as loop 3 next")
    [%{body: %{kind: :loop, count: %{kind: :integer_literal, value: 3}}}] = prog.defs
  end

  test "substring command" do
    prog = parse!("routines ( r ) define r as substring")
    [%{body: %{kind: :substring}}] = prog.defs
  end

  test "among with entries" do
    prog = parse!("""
    routines ( r )
    define r as among ( 'ing' () 'ed' () '' () )
    """)

    [%{body: %{kind: :among, entries: entries}}] = prog.defs
    assert length(entries) == 3
    assert Enum.at(entries, 0).strings == ["ing"]
    assert Enum.at(entries, 1).strings == ["ed"]
    assert Enum.at(entries, 2).strings == [""]
  end

  test "among entry with multiple strings shares action" do
    prog = parse!("""
    routines ( r )
    define r as among ( 'ied' 'ies' (delete) '' () )
    """)

    [%{body: %{kind: :among, entries: entries}}] = prog.defs
    first = Enum.find(entries, fn e -> "ied" in e.strings end)
    assert "ies" in first.strings
    assert first.action != nil
  end

  test "in_grouping via name reference" do
    prog = parse!("groupings ( v ) routines ( r ) define r as v")
    [%{body: %{kind: :in_grouping, grouping: "v"}}] = prog.defs
  end

  test "out_grouping via non keyword" do
    prog = parse!("groupings ( v ) routines ( r ) define r as non v")
    [%{body: %{kind: :out_grouping, grouping: "v"}}] = prog.defs
  end

  test "goto grouping becomes goto_grouping" do
    prog = parse!("groupings ( v ) routines ( r ) define r as goto v")
    [%{body: %{kind: :goto_grouping, grouping: "v"}}] = prog.defs
  end

  test "gopast non-grouping becomes gopast_non" do
    prog = parse!("groupings ( v ) routines ( r ) define r as gopast non v")
    [%{body: %{kind: :gopast_non, grouping: "v"}}] = prog.defs
  end

  test "routine call" do
    prog = parse!("routines ( sub r ) define sub as delete define r as sub")
    [_, %{body: %{kind: :call, routine: "sub"}}] = prog.defs
  end

  test "boolean test via name reference" do
    prog = parse!("booleans ( found ) routines ( r ) define r as found")
    [%{body: %{kind: :booltest, var: "found"}}] = prog.defs
  end

  test "integer $-expression assignment" do
    prog = parse!("integers ( p1 ) routines ( r ) define r as $p1 = cursor")
    [%{body: %{kind: :dollar, var: "p1", op: :assign}}] = prog.defs
  end

  test "setmark" do
    prog = parse!("integers ( m ) routines ( r ) define r as setmark m")
    [%{body: %{kind: :setmark, var: "m"}}] = prog.defs
  end

  test "tomark and atmark" do
    prog = parse!("integers ( m ) routines ( r ) define r as ( tomark m atmark m )")
    [%{body: %{kind: :seq, body: [tm, am]}}] = prog.defs
    assert tm.kind == :tomark
    assert am.kind == :atmark
  end

  test "hop command" do
    prog = parse!("routines ( r ) define r as hop 2")
    [%{body: %{kind: :hop, count: %{kind: :integer_literal, value: 2}}}] = prog.defs
  end

  test "setlimit command" do
    prog = parse!("integers ( m ) routines ( r ) define r as setlimit tomark m for delete")
    [%{body: %{kind: :setlimit}}] = prog.defs
  end

  # ------------------------------------------------------------------
  # Error cases
  # ------------------------------------------------------------------

  test "undeclared name produces error" do
    assert {:error, errors} = parse_err("routines ( r ) define r as undeclared_name")
    assert Enum.any?(errors, fn {msg, _} -> String.contains?(msg, "undeclared") end)
  end

  test "re-declared name produces error" do
    assert {:error, errors} = parse_err("integers ( p1 p1 )")
    assert Enum.any?(errors, fn {msg, _} -> String.contains?(msg, "re-declared") end)
  end

  # ------------------------------------------------------------------
  # Full English-like snippet
  # ------------------------------------------------------------------

  test "parses a realistic Snowball snippet" do
    source = """
    integers ( p1 p2 )
    booleans ( Y_found )
    routines ( mark_regions R1 )
    externals ( stem )
    groupings ( v )
    define v 'aeiouy'
    define mark_regions as (
        $p1 = limit
        do (
            gopast v
            $p1 = cursor
        )
    )
    define R1 as $p1 <= cursor
    define stem as (
        do mark_regions
        backwards (
            do ( [ 'ing' ] delete )
        )
    )
    """

    prog = parse!(source)
    assert prog.kind == :program
    assert map_size(prog.symbols) > 0
    assert length(prog.defs) >= 3
  end
end
