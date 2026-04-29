defmodule Snowball.GeneratorTest do
  use ExUnit.Case, async: true
  doctest Snowball.Generator

  alias Snowball.{Lexer, Analyser, Generator}

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp gen!(source, module_name \\ unique_test_module(), language \\ :test) do
    {:ok, tokens} = Lexer.tokenize(source)
    {:ok, prog} = Analyser.analyse(tokens)
    Generator.generate(prog, module_name, language)
  end

  # Mint a fresh module name per call so repeated `Code.compile_string/1`
  # invocations across tests don't trigger "redefining module" warnings.
  defp unique_test_module do
    Module.concat([Snowball.Stemmers, "GenTest#{System.unique_integer([:positive])}"])
  end

  # Compile a generated source string into a live module and return the module.
  defp compile_src!(src) do
    [{mod, _bytecode}] = Code.compile_string(src)
    mod
  end

  defp stem!(source, word) do
    src = gen!(source)
    mod = compile_src!(src)
    apply(mod, :stem, [word])
  end

  # -----------------------------------------------------------------------
  # Basic structure
  # -----------------------------------------------------------------------

  test "generate returns a binary" do
    src = gen!("externals ( stem ) define stem as delete")
    assert is_binary(src)
  end

  test "generated source contains defmodule" do
    src = gen!("externals ( stem ) define stem as delete", MyTest.Stemmer, :foo)
    assert String.contains?(src, "defmodule MyTest.Stemmer do")
  end

  test "generated source contains stem/1" do
    src = gen!("externals ( stem ) define stem as delete")
    assert String.contains?(src, "def stem(word)")
  end

  test "generated source compiles without errors" do
    src = gen!("externals ( stem ) define stem as delete")
    assert [{_mod, _}] = Code.compile_string(src)
  end

  # -----------------------------------------------------------------------
  # Grouping emission
  # -----------------------------------------------------------------------

  test "groupings are emitted as module attributes when referenced" do
    src =
      gen!("""
      groupings ( v )
      externals ( stem )
      define v 'aeiouy'
      define stem as ( gopast v delete )
      """)

    assert String.contains?(src, "@g_v")
    assert String.contains?(src, "Grouping.from_string")
  end

  test "unreferenced groupings are not emitted" do
    src =
      gen!("""
      groupings ( v )
      externals ( stem )
      define v 'aeiouy'
      define stem as delete
      """)

    refute String.contains?(src, "@g_v")
  end

  # -----------------------------------------------------------------------
  # Round-trip stem correctness
  # -----------------------------------------------------------------------

  test "delete command removes entire word" do
    result = stem!("externals ( stem ) define stem as delete", "hello")
    assert result == ""
  end

  test "true command is a no-op" do
    result = stem!("externals ( stem ) define stem as true", "hello")
    assert result == "hello"
  end

  test "false command leaves word unchanged (do false = no-op)" do
    src = "externals ( stem ) define stem as do false"
    result = stem!(src, "hello")
    assert result == "hello"
  end

  test "eq_s_b (backwards) matches from end then deletes" do
    # [ marks ket=5, 'llo' retreats cursor to 2, ] marks bra=2, delete removes [2,5)
    src = "externals ( stem ) define stem as backwards ( [ 'llo' ] delete )"
    assert stem!(src, "hello") == "he"
  end

  test "do command always succeeds even when body fails" do
    src = "externals ( stem ) define stem as do 'xyz'"
    result = stem!(src, "hello")
    assert result == "hello"
  end

  test "try command restores cursor on failure" do
    src = "externals ( stem ) define stem as try 'xyz'"
    result = stem!(src, "hello")
    assert result == "hello"
  end

  test "not command inverts success" do
    # 'xyz' fails on 'hello', not inverts to success, then delete
    src = "externals ( stem ) define stem as ( not 'xyz' delete )"
    result = stem!(src, "hello")
    assert result == ""
  end

  test "backwards with slice markers deletes suffix" do
    # [ ket=7, 'ing' retreats to 4, ] bra=4, delete removes [4,7)='ing'
    src = "externals ( stem ) define stem as backwards ( [ 'ing' ] delete )"
    assert stem!(src, "running") == "runn"
    assert stem!(src, "hello") == "hello"
  end

  test "repeat advances through all matching chars" do
    # repeat 'a' consumes all leading 'a's
    src = "externals ( stem ) define stem as repeat 'a'"
    assert stem!(src, "aaabbb") == "aaabbb"
  end

  test "or tries alternatives" do
    src = "externals ( stem ) define stem as ( 'xyz' or delete )"
    assert stem!(src, "hello") == ""
  end

  test "literal string match eq_s_b (backwards) retreats cursor" do
    # [ ket=7, 'nning' retreats to 2, ] bra=2, delete removes [2,7)
    src = "externals ( stem ) define stem as backwards ( [ 'nning' ] delete )"
    assert stem!(src, "running") == "ru"
  end

  test "set and booltest" do
    src = """
    booleans ( found )
    externals ( stem )
    define stem as ( set found found delete )
    """

    assert stem!(src, "hello") == ""
  end

  test "unset prevents booltest from passing" do
    src = """
    booleans ( found )
    externals ( stem )
    define stem as ( unset found found or delete )
    """

    assert stem!(src, "hello") == ""
  end

  test "integer setmark and atmark" do
    src = """
    integers ( m )
    externals ( stem )
    define stem as ( setmark m atmark m delete )
    """

    assert stem!(src, "hello") == ""
  end

  test "integer assignment and test" do
    src = """
    integers ( p )
    externals ( stem )
    define stem as ( $p = 3 $(p == 3) delete )
    """

    assert stem!(src, "hello") == ""
  end

  test "hop advances cursor by N codepoints" do
    # backwards: [ ket=5, hop back 3 → cursor=2, ] bra=2, delete [2,5)='llo'
    src = "externals ( stem ) define stem as backwards ( [ hop 3 ] delete )"
    assert stem!(src, "hello") == "he"
  end

  test "tolimit advances to limit" do
    src = "externals ( stem ) define stem as ( tolimit delete )"
    assert stem!(src, "hello") == ""
  end

  test "atlimit succeeds only at limit" do
    src = "externals ( stem ) define stem as ( tolimit atlimit delete )"
    assert stem!(src, "hello") == ""
  end

  test "leftslice and rightslice with delete" do
    src = "externals ( stem ) define stem as backwards ( [ 'ing' ] delete )"
    assert stem!(src, "running") == "runn"
  end

  test "slicefrom replaces slice" do
    src = "externals ( stem ) define stem as backwards ( [ 'ing' ] <- 'ed' )"
    assert stem!(src, "running") == "runned"
  end

  test "among with multiple entries" do
    # `[substring] among(...)` is the correct Snowball pattern for suffix
    # removal: `[substring]` sets ket before the search and bra after, so
    # slice actions operate on the matched suffix region.
    src = """
    externals ( stem )
    define stem as backwards (
      [substring] among ( 'ing' (delete) 'ed' (delete) '' () )
    )
    """

    assert stem!(src, "running") == "runn"
    assert stem!(src, "walked") == "walk"
    assert stem!(src, "hello") == "hello"
  end

  test "among with actions" do
    src = """
    externals ( stem )
    define stem as backwards (
      [substring] among ( 'ies' (<- 'y') 'ing' (delete) '' () )
    )
    """

    assert stem!(src, "running") == "runn"
    assert stem!(src, "flies") == "fly"
  end

  test "routine call" do
    src = """
    routines ( strip_s )
    externals ( stem )
    define strip_s as backwards ( [substring] among ( 's' (delete) '' () ) )
    define stem as strip_s
    """

    assert stem!(src, "cats") == "cat"
    assert stem!(src, "dog") == "dog"
  end

  test "setlimit command" do
    # hop 3 advances cursor to 3; setmark m saves m=3.
    # setlimit tomark m temporarily sets the forward limit to 3,
    # making atlimit succeed because cursor (3) equals the new limit (3).
    # The word is never modified, so it is returned unchanged.
    src = """
    integers ( m )
    externals ( stem )
    define stem as (
      hop 3
      setmark m
      setlimit tomark m for atlimit
    )
    """

    assert stem!(src, "hello") == "hello"
  end

  test "loop command" do
    src = "externals ( stem ) define stem as loop 3 next"
    assert stem!(src, "hello") == "hello"
  end

  test "grouping in_grouping test" do
    src = """
    groupings ( v )
    externals ( stem )
    define v 'aeiou'
    define stem as ( v delete )
    """

    assert stem!(src, "apple") == ""
    assert stem!(src, "bottle") == "bottle"
  end

  test "goto advances to matching position" do
    # goto 'o' leaves cursor BEFORE 'o'; then [ sets bra, 'o' matches, ] sets ket,
    # delete removes just the 'o'.  On a word without 'o' goto fails → word unchanged.
    src = """
    externals ( stem )
    define stem as ( goto 'o' [ 'o' ] delete )
    """

    assert stem!(src, "hello") == "hell"
    assert stem!(src, "city") == "city"
  end

  test "gopast advances past matching position" do
    # gopast 'hel' leaves cursor AFTER 'hel' (at 3); [ sets bra=3, tolimit moves
    # cursor to limit=5, ] sets ket=5, delete removes the trailing "lo" → "hel".
    src = """
    externals ( stem )
    define stem as ( gopast 'hel' [ tolimit ] delete )
    """

    assert stem!(src, "hello") == "hel"
    assert stem!(src, "city") == "city"
  end

  # -----------------------------------------------------------------------
  # Among table emission
  # -----------------------------------------------------------------------

  test "among table is emitted as module attribute" do
    src = gen!("""
    externals ( stem )
    define stem as among ( 'ing' () 'ed' () '' () )
    """)

    assert String.contains?(src, "@a_0")
  end

  # -----------------------------------------------------------------------
  # init_vars
  # -----------------------------------------------------------------------

  test "integers and booleans initialised in init_vars" do
    src = gen!("integers ( p1 ) booleans ( Y_found ) externals ( stem ) define stem as true")
    assert String.contains?(src, "p1: 0")
    assert String.contains?(src, "Y_found: false")
  end
end
