defmodule Snowball.Preprocessor do
  @moduledoc """
  Source-level preprocessor for Snowball `.sbl` files.

  Handles the two Snowball directives that must be resolved before
  tokenisation:

  * `stringescapes LB RB` — declares that `LB name RB` inside string
    literals is a substitution reference (e.g. `stringescapes {}` makes
    `{name}` the substitution syntax).

  * `stringdef name 'value'` — defines a named string alias, where the
    value may use `{U+XXXX}` Unicode escapes.

  After preprocessing the returned source:

  * All `stringescapes` and `stringdef` declarations are removed.

  * Every string literal in the remaining source has its `{U+XXXX}` and
    `{name}` sequences expanded to real UTF-8 characters.

  The resulting source can be fed directly to `Snowball.Lexer.tokenize/1`.

  """

  @doc """
  Preprocess a Snowball source binary.

  ### Arguments

  * `source` is the raw UTF-8 source text.

  ### Returns

  * The preprocessed source binary with all `stringdef` / `stringescapes`
    declarations removed and all string-escape sequences expanded.

  """
  @spec preprocess(binary()) :: binary()
  def preprocess(source) when is_binary(source) do
    {lb, rb} = find_stringescapes(source)
    defs = collect_stringdefs(source, lb, rb)
    source
    |> remove_stringdef_lines()
    |> expand_all_strings(lb, rb, defs)
  end

  # -----------------------------------------------------------------------
  # Step 1: find stringescapes directive
  # -----------------------------------------------------------------------

  defp find_stringescapes(source) do
    # Format: stringescapes LB RB  (or stringescapes LBRB with no space)
    # LB and RB are each a single character.
    case Regex.run(
           ~r/^[ \t]*stringescapes[ \t]+(\S)[ \t]*(\S)?[ \t]*(?:\/\/.*)?$/m,
           source
         ) do
      [_, lb, rb] when rb != "" and rb != nil -> {lb, rb}
      [_, lb] -> {lb, lb}
      nil -> {nil, nil}
    end
  end

  # -----------------------------------------------------------------------
  # Step 2: collect stringdef name → value mappings
  # -----------------------------------------------------------------------

  # Collect all `stringdef <name> '<raw_value>'` declarations.
  # The name may contain characters that are not valid Snowball identifiers
  # (e.g. apostrophe, slash, caret) so we parse it from the raw text.
  defp collect_stringdefs(source, lb, rb) do
    # Match: optional-whitespace "stringdef" whitespace <name> whitespace ' <value> '
    # The name is any non-whitespace run; the value is between single quotes.
    # We find all such lines and build the expansion map.
    Regex.scan(
      ~r/^[ \t]*stringdef[ \t]+(\S+?)[ \t]+'([^']*)'/m,
      source
    )
    |> Enum.reduce(%{}, fn [_, name, raw_value], acc ->
      expanded = expand_escapes(raw_value, lb, rb, acc)
      Map.put(acc, name, expanded)
    end)
  end

  # -----------------------------------------------------------------------
  # Step 3: remove stringescapes and stringdef lines
  # -----------------------------------------------------------------------

  defp remove_stringdef_lines(source) do
    source
    |> String.split("\n")
    |> Enum.reject(&stringdef_line?/1)
    |> Enum.join("\n")
  end

  defp stringdef_line?(line) do
    trimmed = String.trim_leading(line)
    String.starts_with?(trimmed, "stringdef ") or
      String.starts_with?(trimmed, "stringdef\t") or
      String.starts_with?(trimmed, "stringescapes ")
  end

  # -----------------------------------------------------------------------
  # Step 4: expand {U+XXXX} and {name} in every string literal
  # -----------------------------------------------------------------------

  # Walk the source character by character, tracking whether we are inside
  # a single-quoted string literal. When inside a string, expand escape
  # sequences; outside strings, emit characters as-is.
  #
  # Mode is one of:
  #   :normal        — outside any string or comment
  #   :in_string     — inside a single-quoted string literal
  #   :line_comment  — inside a // ... \n comment
  #   :block_comment — inside a /* ... */ comment
  #
  # Only :in_string mode performs escape expansion. All other modes pass
  # characters through verbatim so that single-quote characters inside
  # comments do not disturb the string-tracking state machine.
  defp expand_all_strings(source, lb, rb, defs) do
    expand_source(source, lb, rb, defs, :normal, [])
  end

  # Base case: reverse and join the accumulated binaries.
  defp expand_source(<<>>, _lb, _rb, _defs, _mode, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # ---- Outside string / not in comment (:normal) -------------------------

  # Normal: // starts a line comment.
  defp expand_source(<<"//", rest::binary>>, lb, rb, defs, :normal, acc) do
    expand_source(rest, lb, rb, defs, :line_comment, ["//" | acc])
  end

  # Normal: /* starts a block comment.
  defp expand_source(<<"/*", rest::binary>>, lb, rb, defs, :normal, acc) do
    expand_source(rest, lb, rb, defs, :block_comment, ["/*" | acc])
  end

  # Normal: opening quote → enter string mode.
  defp expand_source(<<?', rest::binary>>, lb, rb, defs, :normal, acc) do
    expand_source(rest, lb, rb, defs, :in_string, ["'" | acc])
  end

  # Normal: any other codepoint — pass through verbatim.
  defp expand_source(<<cp::utf8, rest::binary>>, lb, rb, defs, :normal, acc) do
    expand_source(rest, lb, rb, defs, :normal, [<<cp::utf8>> | acc])
  end

  # ---- Line comment (:line_comment) --------------------------------------

  # Line comment: newline ends the comment.
  defp expand_source(<<?\n, rest::binary>>, lb, rb, defs, :line_comment, acc) do
    expand_source(rest, lb, rb, defs, :normal, ["\n" | acc])
  end

  # Line comment: any other codepoint — pass through verbatim.
  defp expand_source(<<cp::utf8, rest::binary>>, lb, rb, defs, :line_comment, acc) do
    expand_source(rest, lb, rb, defs, :line_comment, [<<cp::utf8>> | acc])
  end

  # ---- Block comment (:block_comment) ------------------------------------

  # Block comment: */ ends the comment.
  defp expand_source(<<"*/", rest::binary>>, lb, rb, defs, :block_comment, acc) do
    expand_source(rest, lb, rb, defs, :normal, ["*/" | acc])
  end

  # Block comment: any other codepoint — pass through verbatim.
  defp expand_source(<<cp::utf8, rest::binary>>, lb, rb, defs, :block_comment, acc) do
    expand_source(rest, lb, rb, defs, :block_comment, [<<cp::utf8>> | acc])
  end

  # ---- Inside string (:in_string) ----------------------------------------

  # In string: closing quote → return to normal mode.
  defp expand_source(<<?', rest::binary>>, lb, rb, defs, :in_string, acc) do
    expand_source(rest, lb, rb, defs, :normal, ["'" | acc])
  end

  # In string: opening escape delimiter when lb == "{".
  defp expand_source(<<"{", rest::binary>>, lb, rb, defs, :in_string, acc) when lb == "{" do
    case extract_escape(rest, rb) do
      {escape_name, after_escape} ->
        replacement = resolve_escape(escape_name, defs)
        expand_source(after_escape, lb, rb, defs, :in_string, [replacement | acc])

      :no_close ->
        # Unmatched `{` — pass through literally.
        expand_source(rest, lb, rb, defs, :in_string, ["{" | acc])
    end
  end

  # In string: ordinary codepoint — pass through verbatim.
  defp expand_source(<<cp::utf8, rest::binary>>, lb, rb, defs, :in_string, acc) do
    expand_source(rest, lb, rb, defs, :in_string, [<<cp::utf8>> | acc])
  end

  # Extract the content between lb and rb (rb is typically "}").
  defp extract_escape(rest, rb) do
    extract_escape_acc(rest, rb, [])
  end

  defp extract_escape_acc(<<>>, _rb, _acc), do: :no_close

  defp extract_escape_acc(<<char::utf8, rest::binary>>, rb, acc)
       when <<char::utf8>> == rb do
    {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}
  end

  defp extract_escape_acc(<<char::utf8, rest::binary>>, rb, acc) do
    extract_escape_acc(rest, rb, [<<char::utf8>> | acc])
  end

  # -----------------------------------------------------------------------
  # Escape resolution helpers
  # -----------------------------------------------------------------------

  # Expand a single escape sequence: either {U+XXXX} or {name}.
  defp expand_escapes(raw, lb, _rb, defs) do
    if lb == "{" do
      Regex.replace(~r/\{([^}]*)\}/, raw, fn _, name ->
        resolve_escape(name, defs)
      end)
    else
      expand_unicode_escapes(raw)
    end
  end

  # Always expand {U+XXXX} to the actual Unicode codepoint.
  defp expand_unicode_escapes(raw) do
    Regex.replace(~r/\{U\+([0-9A-Fa-f]+)\}/i, raw, fn _, hex ->
      {cp, ""} = Integer.parse(hex, 16)
      <<cp::utf8>>
    end)
  end

  # Resolve a single escape name: Unicode codepoint takes priority, then
  # fall back to the stringdef map.
  defp resolve_escape(name, defs) do
    if Regex.match?(~r/^U\+[0-9A-Fa-f]+$/i, name) do
      # {U+XXXX} — Unicode codepoint escape (always supported).
      hex = String.slice(name, 2..-1//1)
      {cp, ""} = Integer.parse(hex, 16)
      <<cp::utf8>>
    else
      case Map.get(defs, name) do
        nil ->
          # Unknown name — emit the original escape verbatim so the lexer
          # can handle or reject it.
          "{" <> name <> "}"

        value ->
          value
      end
    end
  end
end
