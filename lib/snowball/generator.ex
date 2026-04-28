defmodule Snowball.Generator do
  @moduledoc """
  Elixir code generator for Snowball programs.

  Takes a `t:Snowball.Analyser.program/0` AST and emits a self-contained
  Elixir module source string that can be written to disk and compiled.

  The generated module follows exactly the same runtime conventions as the
  hand-ported `Snowball.Stemmers.English`:

  * Groupings are compiled to bit-tables via `Snowball.Grouping.from_string/1`
    at module load time.

  * Among tables are sorted and assigned result codes at code-gen time so
    the runtime binary-search works correctly.

  * Every routine is a private `defp` returning `{:ok, state} | {:fail, state}`.

  * The `snowball_do/2`, `snowball_try/2`, and `snowball_or/3` combinators
    plus `lift/2` and `next_codepoint/1` helpers are inlined into every
    generated module.

  """

  alias Snowball.Analyser

  # -----------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------

  @doc """
  Generate an Elixir module source string from a Snowball program AST.

  ### Arguments

  * `program` is the `t:Snowball.Analyser.program/0` map returned by
    `Snowball.Analyser.analyse/1`.

  * `module_name` is the fully-qualified atom for the generated module,
    e.g. `Snowball.Stemmers.English`.

  * `language` is the language atom used in the public facade, e.g.
    `:english`.

  ### Returns

  * A UTF-8 binary containing the complete Elixir source for the module.

  ### Examples

      iex> {:ok, tokens} = Snowball.Lexer.tokenize("externals ( stem ) define stem as delete")
      iex> {:ok, prog} = Snowball.Analyser.analyse(tokens)
      iex> src = Snowball.Generator.generate(prog, Snowball.Stemmers.Tiny, :tiny)
      iex> is_binary(src)
      true

  """
  @spec generate(Analyser.program(), module(), atom()) :: binary()
  def generate(program, module_name, language) do
    ctx = build_context(program)
    routines_code = emit_routines(program, ctx)
    used_groupings = collect_used_groupings(routines_code)
    grouping_ctx = %{ctx | groupings: Map.take(ctx.groupings, MapSet.to_list(used_groupings))}

    IO.iodata_to_binary([
      emit_header(module_name, language, grouping_ctx),
      emit_dialyzer_suppressions(language),
      emit_groupings(grouping_ctx),
      emit_among_tables(ctx),
      emit_scan_maps(ctx),
      emit_stem_fn(program),
      emit_init_vars(program),
      emit_run_stem(program),
      emit_combinators(routines_code),
      routines_code,
      emit_footer()
    ])
  end

  # Scan generated routine code for `@g_<name>` references so we only emit
  # the module attributes that are actually used. Snowball sources sometimes
  # declare more groupings than any routine ends up referencing.
  defp collect_used_groupings(routines_code) do
    ~r/@g_([A-Za-z_][A-Za-z_0-9]*)/
    |> Regex.scan(routines_code, capture: :all_but_first)
    |> Enum.map(fn [name] -> name end)
    |> MapSet.new()
  end

  # -----------------------------------------------------------------------
  # Context — grouping tables and among tables collected from the AST
  # -----------------------------------------------------------------------

  defp build_context(program) do
    groupings =
      program.defs
      |> Enum.filter(&(&1.kind == :define_grouping))
      |> Enum.map(fn %{name: name, strings: parts} ->
        {name, expand_grouping(parts, program)}
      end)
      |> Map.new()

    amongs = collect_amongs_defs(program.defs, [], program.symbols) |> Enum.with_index()

    method_among_indices =
      amongs
      |> Enum.filter(fn {{node, _mode}, _idx} ->
        among_has_methods?(node) or among_has_constraint_entries?(node) or
          among_has_entry_constraints?(node)
      end)
      |> Enum.map(fn {_, idx} -> idx end)
      |> MapSet.new()

    scan_maps = collect_scan_patterns(program.defs, program.symbols)

    %{groupings: groupings, amongs: amongs, symbols: program.symbols, method_among_indices: method_among_indices, scan_maps: scan_maps}
  end

  defp expand_grouping(parts, program) do
    # Separate add-parts from subtract-parts, then take the set difference.
    {add_parts, subtract_parts} =
      Enum.reduce(parts, {[], []}, fn
        {:grouping_ref, name}, {a, s} ->
          {a ++ [lookup_grouping_def(name, program)], s}

        {:grouping_minus_ref, name}, {a, s} ->
          {a, s ++ [lookup_grouping_def(name, program)]}

        {:grouping_minus_cp, cp}, {a, s} ->
          {a, s ++ [[cp]]}

        cp, {a, s} when is_binary(cp) ->
          {a ++ [[cp]], s}
      end)

    add_chars = List.flatten(add_parts)
    sub_set = add_chars |> Enum.filter(&(&1 in List.flatten(subtract_parts))) |> MapSet.new()

    add_chars
    |> Enum.reject(&MapSet.member?(sub_set, &1))
    |> Enum.uniq()
  end

  defp lookup_grouping_def(name, program) do
    case Enum.find(program.defs, fn d ->
           d.kind == :define_grouping and d.name == name
         end) do
      nil -> []
      %{strings: sub_parts} -> expand_grouping(sub_parts, program)
    end
  end

  # Collect {node, mode} pairs for all among nodes, tracking scanning mode.
  # The initial mode for each routine comes from its symbol-table entry so that
  # routines defined inside backwardmode(...) are collected in :backward mode.
  defp collect_amongs_defs(defs, acc, symbols) do
    Enum.reduce(defs, acc, fn
      %{kind: :define_routine, name: name, body: body}, a ->
        initial_mode =
          case Map.get(symbols, name) do
            %{mode: :backward} -> :backward
            _ -> :forward
          end

        collect_amongs_node(body, initial_mode, a)

      _, a ->
        a
    end)
    |> Enum.reverse()
  end

  defp collect_amongs_node(nil, _mode, acc), do: acc

  defp collect_amongs_node(%{kind: :among} = node, mode, acc) do
    acc =
      Enum.reduce(node.entries, acc, fn entry, a ->
        case entry.action do
          nil -> a
          action -> collect_amongs_node(action, mode, a)
        end
      end)

    acc =
      case Map.get(node, :default_action) do
        nil -> acc
        da -> collect_amongs_node(da, mode, acc)
      end

    [{node, mode} | acc]
  end

  defp collect_amongs_node(%{kind: :test_among, among: among}, mode, acc) do
    collect_amongs_node(among, mode, acc)
  end

  defp collect_amongs_node(%{kind: :backwards, body: body}, _mode, acc) do
    collect_amongs_node(body, :backward, acc)
  end

  defp collect_amongs_node(%{kind: :reverse, body: body}, mode, acc) do
    new_mode = if mode == :forward, do: :backward, else: :forward
    collect_amongs_node(body, new_mode, acc)
  end

  defp collect_amongs_node(%{kind: :seq, body: cmds}, mode, acc) do
    Enum.reduce(cmds, acc, fn cmd, a -> collect_amongs_node(cmd, mode, a) end)
  end

  defp collect_amongs_node(%{kind: :slice_among, among: among, restrictions: restrictions}, mode, acc) do
    acc1 = collect_amongs_node(among, mode, acc)
    Enum.reduce(restrictions, acc1, fn r, a -> collect_amongs_node(r, mode, a) end)
  end

  defp collect_amongs_node(%{kind: :restricted_among, among: among, restrictions: restrictions}, mode, acc) do
    acc1 = collect_amongs_node(among, mode, acc)
    Enum.reduce(restrictions, acc1, fn r, a -> collect_amongs_node(r, mode, a) end)
  end

  defp collect_amongs_node(
         %{kind: :setlimit_slice_among, among: among, restrictions: restrictions, limit_cmd: limit_cmd},
         mode,
         acc
       ) do
    acc1 = collect_amongs_node(among, mode, acc)
    acc2 = collect_amongs_node(limit_cmd, mode, acc1)
    Enum.reduce(restrictions, acc2, fn r, a -> collect_amongs_node(r, mode, a) end)
  end

  defp collect_amongs_node(node, mode, acc) when is_map(node) do
    acc
    |> maybe_collect(Map.get(node, :body), mode)
    |> maybe_collect(Map.get(node, :left), mode)
    |> maybe_collect(Map.get(node, :right), mode)
    |> maybe_collect(Map.get(node, :limit_cmd), mode)
  end

  defp maybe_collect(acc, nil, _mode), do: acc
  defp maybe_collect(acc, node, mode), do: collect_amongs_node(node, mode, acc)

  # -----------------------------------------------------------------------
  # Scan-pattern collection (for scan_and_replace_forward optimisation)
  # -----------------------------------------------------------------------

  # Collect all `{among_node, :forward}` pairs for repeat bodies that match the
  # pattern `or(slice_among_no_restrictions, next)` where every among entry has
  # a single-codepoint string and a simple delete/slicefrom/no-op action.
  defp collect_scan_patterns(defs, symbols) do
    defs
    |> Enum.filter(fn d -> d.kind == :define_routine end)
    |> Enum.flat_map(fn %{name: name, body: body} ->
      initial_mode =
        case Map.get(symbols, name) do
          %{mode: :backward} -> :backward
          _ -> :forward
        end

      collect_scan_nodes(body, initial_mode)
    end)
    |> Enum.uniq()
    |> Enum.with_index()
  end

  defp collect_scan_nodes(nil, _mode), do: []

  # Lists arise from :seq nodes whose `body` field is a list of commands.
  defp collect_scan_nodes(nodes, mode) when is_list(nodes) do
    Enum.flat_map(nodes, &collect_scan_nodes(&1, mode))
  end

  defp collect_scan_nodes(%{kind: :repeat, body: body}, :forward) do
    scan_pattern_node(body) ++ collect_scan_nodes(body, :forward)
  end

  defp collect_scan_nodes(%{kind: :backwards, body: body}, _mode) do
    collect_scan_nodes(body, :backward)
  end

  defp collect_scan_nodes(%{kind: :reverse, body: body}, mode) do
    new_mode = if mode == :forward, do: :backward, else: :forward
    collect_scan_nodes(body, new_mode)
  end

  defp collect_scan_nodes(node, mode) when is_map(node) do
    [:body, :left, :right, :limit_cmd]
    |> Enum.flat_map(fn field ->
      case Map.get(node, field) do
        nil -> []
        child -> collect_scan_nodes(child, mode)
      end
    end)
  end

  # Non-map, non-list leaf values (atoms, strings, integers, tuples) — no children.
  defp collect_scan_nodes(_leaf, _mode), do: []

  # Returns `[{among_node, :forward}]` if `body` is the scan pattern, else `[]`.
  # Two forms are handled:
  #   1. Direct: `or(slice_among, next)` — the slice_among is the immediate left arm.
  #   2. Wrapped: `or(seq([slice_among]), next)` — Snowball parentheses `( [substring] among(...) )`
  #      produce a single-element :seq node that wraps the slice_among.  The Arabic algorithm
  #      uses this form, so both must be recognised for the optimisation to fire.
  defp scan_pattern_node(%{
         kind: :or,
         left: %{kind: :slice_among, among: among_node, restrictions: []},
         right: %{kind: :next}
       }) do
    if scan_eligible_among?(among_node), do: [{among_node, :forward}], else: []
  end

  defp scan_pattern_node(%{
         kind: :or,
         left: %{kind: :seq, body: [%{kind: :slice_among, among: among_node, restrictions: []}]},
         right: %{kind: :next}
       }) do
    if scan_eligible_among?(among_node), do: [{among_node, :forward}], else: []
  end

  defp scan_pattern_node(_), do: []

  # True when the among node is safe to replace with a single-pass char scan:
  # no method/constraint entries, no default action, every string is exactly
  # one Unicode codepoint, every action is delete, slicefrom-literal, or no-op.
  defp scan_eligible_among?(%{kind: :among, entries: entries} = node) do
    not among_has_methods?(node) and
      not among_has_constraint_entries?(node) and
      not among_has_entry_constraints?(node) and
      is_nil(Map.get(node, :default_action)) and
      Enum.all?(entries, &scan_eligible_entry?/1)
  end

  defp scan_eligible_among?(_), do: false

  defp scan_eligible_entry?(%{strings: strings, action: action}) do
    Enum.all?(strings, fn s -> match?(<<_::utf8>>, s) end) and
      case action do
        nil -> true
        %{kind: :seq, body: []} -> true
        %{kind: :delete} -> true
        %{kind: :slicefrom, arg: {:literal, _}} -> true
        _ -> false
      end
  end

  # -----------------------------------------------------------------------
  # Code sections
  # -----------------------------------------------------------------------

  defp emit_header(module_name, language, ctx) do
    mod_str = inspect(module_name)
    grouping_alias =
      if map_size(ctx.groupings) > 0, do: "  alias Snowball.Grouping\n", else: ""

    "# Generated by Snowball.Generator — do not edit by hand.\n" <>
      "defmodule #{mod_str} do\n" <>
      "  @moduledoc \"\"\"\n" <>
      "  Snowball stemmer for #{language}.\n" <>
      "\n" <>
      "  Generated from the canonical Snowball algorithm source.\n" <>
      "  \"\"\"\n" <>
      "\n" <>
      "  alias Snowball.Stemmer\n" <>
      grouping_alias <>
      "\n"
  end

  defp emit_footer, do: "end\n"

  # Targeted suppression for pattern_match_cov warnings that our always_succeeds?
  # analysis cannot eliminate. The affected routines contain backwards-chain or
  # among-dispatch paths whose reachability Dialyzer cannot prove statically.
  defp emit_dialyzer_suppressions(:dutch) do
    "  @dialyzer {:no_match, {:r_stem, 1}}\n\n"
  end

  defp emit_dialyzer_suppressions(:greek) do
    "  @dialyzer {:no_match, {:r_step_s3, 1}}\n\n"
  end

  defp emit_dialyzer_suppressions(_language), do: ""

  defp emit_groupings(%{groupings: groupings}) when map_size(groupings) == 0, do: ""

  defp emit_groupings(%{groupings: groupings}) do
    lines =
      Enum.map(groupings, fn {name, codepoints} ->
        str = Enum.join(codepoints)
        "  @g_#{name} Grouping.from_string(#{inspect(str)})\n"
      end)

    "\n  # Groupings\n" <> Enum.join(lines) <> "\n"
  end

  defp emit_among_tables(ctx) do
    # Skip among tables whose scan map has been generated — those amongs are
    # accessed via `Stemmer.scan_and_replace_forward/2` and the `@a_N`
    # attribute would never be referenced, producing an unused-attribute warning.
    scan_keys = MapSet.new(ctx.scan_maps, fn {{node, mode}, _} -> {node, mode} end)

    tables =
      ctx.amongs
      |> Enum.reject(fn {{node, mode}, _} -> MapSet.member?(scan_keys, {node, mode}) end)
      |> Enum.map(fn {{among_node, mode}, idx} -> emit_single_among(among_node, mode, idx) end)

    case tables do
      [] -> ""
      _ -> "\n  # Among tables\n" <> Enum.join(tables, "") <> "\n"
    end
  end

  defp emit_scan_maps(%{scan_maps: []}), do: ""

  defp emit_scan_maps(%{scan_maps: scan_maps}) do
    lines =
      Enum.map_join(scan_maps, "", fn {{among_node, _mode}, idx} ->
        char_map = build_scan_map(among_node.entries)

        map_code =
          char_map
          |> Enum.sort_by(fn {cp, _} -> cp end)
          |> Enum.map_join(", ", fn {cp, repl} -> "#{cp} => #{inspect(repl)}" end)

        "  @scan_#{idx} %{#{map_code}}\n"
      end)

    "\n  # Scan-and-replace character maps\n" <> lines <> "\n"
  end

  # Build a `%{codepoint_integer => replacement_binary}` map from among entries.
  # Entries with delete action map to ""; entries with slicefrom-literal map to
  # the literal string.  No-op entries (nil / empty seq) are omitted — characters
  # not in the map are passed through unchanged by scan_and_replace_forward.
  defp build_scan_map(entries) do
    Enum.reduce(entries, %{}, fn %{strings: strings, action: action}, acc ->
      case action do
        %{kind: :delete} ->
          Enum.reduce(strings, acc, fn s, a ->
            <<cp::utf8>> = s
            Map.put(a, cp, "")
          end)

        %{kind: :slicefrom, arg: {:literal, repl}} ->
          Enum.reduce(strings, acc, fn s, a ->
            <<cp::utf8>> = s
            Map.put(a, cp, repl)
          end)

        _ ->
          acc
      end
    end)
  end

  defp emit_single_among(%{kind: :among, entries: entries} = node, mode, idx) do
    cond do
      among_has_entry_constraints?(node) ->
        # New-style per-entry constraints: groups have a `constraints` field
        # (list of routine names, parallel to `strings`).  Each string gets its
        # own closure in the among table's 4th-param slot, and result codes are
        # assigned by the group's action — the same way as standard amongs but
        # with closures added.  Closures cannot be stored in module attributes.
        flat = flatten_among_entries_with_entry_constraints(entries)
        sorted = sort_among_methods(flat, mode)
        table_code = Enum.map_join(sorted, ",\n      ", &format_method_entry/1)
        "  defp a_#{idx} do\n    [\n      #{table_code}\n    ]\n  end\n"

      among_has_methods?(node) ->
        # Legacy pure method-in-find_among pattern (old Lovins / Hindi code):
        # every entry is a constraint call, all sharing result=1.  Kept for
        # backward compatibility with any pre-generated modules; new code
        # generated by the analyser no longer produces constraint-call actions.
        flat = flatten_among_method_entries(entries)
        sorted = sort_among_methods(flat, mode)
        table_code = Enum.map_join(sorted, ",\n      ", &format_method_entry/1)
        "  defp a_#{idx} do\n    [\n      #{table_code}\n    ]\n  end\n"

      among_has_constraint_entries?(node) ->
        # Legacy mixed constraint among (old Finnish / similar): some entries
        # have constraint-call actions, some have regular actions.  Kept for
        # backward compatibility.
        flat = flatten_among_entries_with_closures(entries)
        sorted = sort_among_methods(flat, mode)
        table_code = Enum.map_join(sorted, ",\n      ", &format_method_entry/1)
        "  defp a_#{idx} do\n    [\n      #{table_code}\n    ]\n  end\n"

      true ->
        # Standard among: no closures, stored as a module attribute.
        {flat, _} = flatten_among_entries(entries)
        sorted = sort_among(flat, mode)
        table_code = Enum.map_join(sorted, ",\n    ", &format_among_entry/1)
        "  @a_#{idx} [\n    #{table_code}\n  ]\n"
    end
  end

  # True for the pure method-in-find_among pattern:
  # - ALL entries are either bare-name constraint calls (marked with
  #   constraint: true by the analyser), nil-action, or empty seqs.
  # - At least one entry has a constraint call.
  # - No per-entry actions that would need individual result-number dispatch.
  # Covers both Lovins (with a default_action inside the among) and Hindi
  # (where the delete is outside the among block, so default_action is nil).
  defp among_has_methods?(%{kind: :among} = node) do
    Enum.any?(node.entries, fn e -> match?(%{kind: :call, constraint: true}, e.action) end) and
      Enum.all?(node.entries, fn e ->
        case e.action do
          %{kind: :call, constraint: true} -> true
          nil -> true
          %{kind: :seq, body: []} -> true
          _ -> false
        end
      end)
  end

  defp among_has_methods?(_), do: false

  # True when the among has at least one bare-name constraint call entry
  # (marked with constraint: true by the analyser) AND at least one entry
  # with a per-entry action that needs result-number dispatch.  This is the
  # mixed pattern (e.g. Finnish case_ending).
  defp among_has_constraint_entries?(%{kind: :among} = node) do
    Enum.any?(node.entries, fn e -> match?(%{kind: :call, constraint: true}, e.action) end) and
      not among_has_methods?(node)
  end

  defp among_has_constraint_entries?(_), do: false

  # True when at least one group in the among has a `constraints` field —
  # the new-style per-entry constraint model produced by the analyser when
  # bare routine names appear in `among(...)` blocks (e.g. `'a' R1 'o' R1`).
  defp among_has_entry_constraints?(%{kind: :among} = node) do
    Enum.any?(node.entries, fn e -> Map.has_key?(e, :constraints) end)
  end

  defp among_has_entry_constraints?(_), do: false

  # Flatten entry groups that carry per-entry constraints (the new model).
  # Each group has `strings`, `action`, and optionally `constraints` (a list
  # of routine name strings or nils, parallel to `strings`).  Result codes
  # are assigned the same way as `flatten_among_entries/1` (sequentially by
  # group action), and each string gets its individual constraint routine.
  # Returns 3-tuples `{string, result, routine_or_nil}`.
  defp flatten_among_entries_with_entry_constraints(groups) do
    {flat, _} =
      Enum.reduce(groups, {[], 1}, fn group, {acc, result_n} ->
        %{strings: strings, action: action} = group
        constraints = Map.get(group, :constraints)

        result =
          case action do
            nil -> -1
            %{kind: :seq, body: []} -> -1
            _ -> result_n
          end

        next_n = if result == -1, do: result_n, else: result_n + 1

        entries =
          strings
          |> Enum.with_index()
          |> Enum.map(fn {s, i} ->
            routine = if constraints, do: Enum.at(constraints, i), else: nil
            {s, result, routine}
          end)

        {acc ++ entries, next_n}
      end)

    flat
  end

  # Flatten entries for a pure method among (Lovins / Hindi style):
  # constraint call entries get result=1 + the routine name;
  # no-action entries get result=-1.
  defp flatten_among_method_entries(groups) do
    Enum.flat_map(groups, fn %{strings: strings, action: action} ->
      case action do
        %{kind: :call, constraint: true, routine: routine} ->
          Enum.map(strings, fn s -> {s, 1, routine} end)

        _ ->
          Enum.map(strings, fn s -> {s, -1, nil} end)
      end
    end)
  end

  # Flatten entries for a mixed constraint among (e.g. Finnish case_ending):
  # assigns sequential result numbers just like flatten_among_entries/1, but
  # also records the routine name for bare-name constraint entries so closures
  # can be embedded in the table for find_among_b fallback.
  # Returns 3-tuples {string, result, routine_or_nil}.
  defp flatten_among_entries_with_closures(groups) do
    {flat, _} =
      Enum.reduce(groups, {[], 1}, fn %{strings: strings, action: action}, {acc, result_n} ->
        {result, routine} =
          case action do
            nil -> {-1, nil}
            %{kind: :seq, body: []} -> {-1, nil}
            %{kind: :call, constraint: true, routine: r} -> {result_n, r}
            %{kind: :call, routine: r} -> {result_n, r}
            _ -> {result_n, nil}
          end

        next_n = if result == -1, do: result_n, else: result_n + 1
        entries = Enum.map(strings, fn s -> {s, result, routine} end)
        {acc ++ entries, next_n}
      end)

    flat
  end

  defp sort_among_methods(flat, :backward) do
    flat
    |> Enum.sort_by(fn {s, _, _} -> :binary.list_to_bin(Enum.reverse(:binary.bin_to_list(s))) end)
    |> compute_substring_i_methods(:backward)
  end

  defp sort_among_methods(flat, _mode) do
    flat
    |> Enum.sort_by(fn {s, _, _} -> s end)
    |> compute_substring_i_methods(:forward)
  end

  defp compute_substring_i_methods(entries, mode) do
    vec = List.to_tuple(entries)
    n = tuple_size(vec)

    Enum.map(0..(n - 1), fn i ->
      {s, result, routine} = elem(vec, i)

      sub_i =
        Enum.reduce((i - 1)..0//-1, -1, fn j, acc ->
          if acc != -1 do
            acc
          else
            {t, _, _} = elem(vec, j)

            match =
              if mode == :backward,
                do: String.ends_with?(s, t) and t != s,
                else: String.starts_with?(s, t) and t != s

            if match, do: j, else: -1
          end
        end)

      {s, sub_i, result, routine}
    end)
  end

  defp format_method_entry({s, sub_i, result, nil}) do
    "{#{inspect(s)}, #{sub_i}, #{result}, nil}"
  end

  defp format_method_entry({s, sub_i, result, routine}) do
    fn_code = "fn state -> case r_#{routine}(state) do {:ok, s} -> s; _ -> :fail end end"
    "{#{inspect(s)}, #{sub_i}, #{result}, #{fn_code}}"
  end

  defp flatten_among_entries(groups) do
    {flat, next_result} =
      Enum.reduce(groups, {[], 1}, fn %{strings: strings, action: action}, {acc, result_n} ->
        result =
          case action do
            nil -> -1
            %{kind: :seq, body: []} -> -1
            _ -> result_n
          end

        next_n = if result == -1, do: result_n, else: result_n + 1
        entries = Enum.map(strings, fn s -> {s, result} end)
        {acc ++ entries, next_n}
      end)

    {flat, next_result - 1}
  end

  # Forward among: sort lexicographically; backward: sort by byte-reversed string
  # so that find_among_b's backward binary search (which compares bytes right-to-left)
  # works correctly. String.reverse/1 reverses codepoints, not bytes, which gives a
  # different order for multi-byte UTF-8 codepoints (e.g. "į" = 0xC4 0xAF).
  defp sort_among(flat, :backward) do
    flat
    |> Enum.sort_by(fn {s, _} -> :binary.list_to_bin(Enum.reverse(:binary.bin_to_list(s))) end)
    |> compute_substring_i(:backward)
  end

  defp sort_among(flat, _mode) do
    flat
    |> Enum.sort_by(fn {s, _} -> s end)
    |> compute_substring_i(:forward)
  end

  defp compute_substring_i(entries, mode) do
    vec = List.to_tuple(entries)
    n = tuple_size(vec)

    Enum.map(0..(n - 1), fn i ->
      {s, result} = elem(vec, i)

      sub_i =
        Enum.reduce((i - 1)..0//-1, -1, fn j, acc ->
          if acc != -1 do
            acc
          else
            {t, _} = elem(vec, j)
            # Forward: t is a proper prefix of s. Backward: t is a proper suffix of s.
            match =
              if mode == :backward,
                do: String.ends_with?(s, t) and t != s,
                else: String.starts_with?(s, t) and t != s

            if match, do: j, else: -1
          end
        end)

      {s, sub_i, result}
    end)
  end

  defp format_among_entry({s, sub_i, result}) do
    "{#{inspect(s)}, #{sub_i}, #{result}, nil}"
  end

  # -----------------------------------------------------------------------
  # stem/1 public function
  # -----------------------------------------------------------------------

  defp emit_stem_fn(_program) do
    "  @doc \"\"\"\n" <>
      "  Stem a word.\n" <>
      "\n" <>
      "  ### Arguments\n" <>
      "\n" <>
      "  * `word` is a UTF-8 binary.\n" <>
      "\n" <>
      "  ### Returns\n" <>
      "\n" <>
      "  * The stemmed UTF-8 binary.\n" <>
      "\n" <>
      "  \"\"\"\n" <>
      "  @spec stem(binary()) :: binary()\n" <>
      "  def stem(word) when is_binary(word) do\n" <>
      "    state = Stemmer.new(word) |> init_vars()\n" <>
      "    state = run_stem(state)\n" <>
      "    Stemmer.assign_to(state)\n" <>
      "  end\n\n"
  end

  defp emit_init_vars(program) do
    # Map literal keys use keyword syntax "name: value", not ":name: value".
    int_vars =
      program.symbols
      |> Enum.filter(fn {_, %{type: t}} -> t == :integer end)
      |> Enum.map(fn {name, _} -> "#{name}: 0" end)

    bool_vars =
      program.symbols
      |> Enum.filter(fn {_, %{type: t}} -> t == :boolean end)
      |> Enum.map(fn {name, _} -> "#{name}: false" end)

    string_vars =
      program.symbols
      |> Enum.filter(fn {_, %{type: t}} -> t == :string end)
      |> Enum.map(fn {name, _} -> "#{name}: \"\"" end)

    all_vars = int_vars ++ bool_vars ++ string_vars

    if all_vars == [] do
      "  defp init_vars(state), do: state\n\n"
    else
      vars_str = Enum.join(all_vars, ", ")
      "  defp init_vars(state), do: %{state | vars: %{#{vars_str}}}\n\n"
    end
  end

  # -----------------------------------------------------------------------
  # run_stem — calls external routines in order
  # -----------------------------------------------------------------------

  defp emit_run_stem(program) do
    externals =
      program.symbols
      |> Enum.filter(fn {_, %{type: t}} -> t == :external end)
      |> Enum.map(fn {name, _} -> name end)

    calls =
      Enum.map_join(externals, "\n", fn name ->
        "    {_, state} = r_#{name}(state)"
      end)

    body =
      if calls == "" do
        "    state"
      else
        calls <> "\n    state"
      end

    "  defp run_stem(%Stemmer{} = state) do\n" <>
      body <> "\n" <>
      "  end\n\n"
  end

  # -----------------------------------------------------------------------
  # Snowball combinator helpers (inlined into every generated module)
  # -----------------------------------------------------------------------

  # Emit only the combinator helpers that are actually referenced in the
  # generated routine code.  Unused helpers trigger Dialyzer and Elixir
  # compiler warnings in every stemmer module, so we skip any that aren't
  # needed.  The check is a plain substring search on the routines source.
  defp emit_combinators(body_code) do
    used? = fn name -> String.contains?(body_code, name <> "(") end

    parts =
      []
      # Forward do: save absolute cursor, always restore it (ref C: int V=z->c; ... z->c=V).
      |> maybe_emit(used?.("snowball_do_f"),
          "  defp snowball_do_f(state, fun) do\n" <>
          "    saved_c = state.cursor\n" <>
          "    {_, s} = fun.(state)\n" <>
          "    %{s | cursor: saved_c}\n" <>
          "  end\n\n")
      # Backward do: save relative cursor, always restore it (ref C: int V=z->l-z->c; ... z->c=z->l-V).
      |> maybe_emit(used?.("snowball_do_b"),
          "  defp snowball_do_b(state, fun) do\n" <>
          "    rel = state.limit - state.cursor\n" <>
          "    {_, s} = fun.(state)\n" <>
          "    %{s | cursor: s.limit - rel}\n" <>
          "  end\n\n")
      # Forward test: restore cursor on both success and failure (Snowball `test` is a pure
      # lookahead — cursor always returns to its original position regardless of outcome).
      |> maybe_emit(used?.("snowball_test_f"),
          "  defp snowball_test_f(state, fun) do\n" <>
          "    saved_c = state.cursor\n" <>
          "    case fun.(state) do\n" <>
          "      {:ok, s} -> {:ok, %{s | cursor: saved_c}}\n" <>
          "      {:fail, s} -> {:fail, %{s | cursor: saved_c}}\n" <>
          "    end\n" <>
          "  end\n\n")
      # Backward test: restore relative cursor on both success and failure.
      |> maybe_emit(used?.("snowball_test_b"),
          "  defp snowball_test_b(state, fun) do\n" <>
          "    rel = state.limit - state.cursor\n" <>
          "    case fun.(state) do\n" <>
          "      {:ok, s} -> {:ok, %{s | cursor: s.limit - rel}}\n" <>
          "      {:fail, s} -> {:fail, %{s | cursor: s.limit - rel}}\n" <>
          "    end\n" <>
          "  end\n\n")
      |> maybe_emit(used?.("snowball_try"),
          "  defp snowball_try(state, fun) do\n" <>
          "    rel = state.limit - state.cursor\n" <>
          "    case fun.(state) do\n" <>
          "      {:ok, s} -> s\n" <>
          "      {:fail, s} -> %{s | cursor: s.limit - rel}\n" <>
          "    end\n" <>
          "  end\n\n")
      |> maybe_emit(used?.("snowball_or"),
          "  defp snowball_or(state, fun1, fun2) do\n" <>
          "    rel = state.limit - state.cursor\n" <>
          "    case fun1.(state) do\n" <>
          "      {:ok, s} -> {:ok, s}\n" <>
          "      {:fail, s} -> fun2.(%{s | cursor: s.limit - rel})\n" <>
          "    end\n" <>
          "  end\n\n")
      |> maybe_emit(used?.("lift"),
          "  defp lift(state, :fail), do: {:fail, state}\n" <>
          "  defp lift(_state, %Stemmer{} = s), do: {:ok, s}\n\n")
      |> maybe_emit(String.contains?(body_code, "next_codepoint("),
          "  defp next_codepoint(%Stemmer{cursor: c, limit: lim, current: cur} = state) do\n" <>
          "    case Stemmer.codepoint_at(cur, c, lim) do\n" <>
          "      {_cp, size} -> {:ok, %{state | cursor: c + size}}\n" <>
          "      :error -> {:fail, state}\n" <>
          "    end\n" <>
          "  end\n\n")
      |> maybe_emit(String.contains?(body_code, "next_codepoint_b("),
          "  defp next_codepoint_b(%Stemmer{cursor: c, limit_backward: lb, current: cur} = state) do\n" <>
          "    case Stemmer.codepoint_before(cur, c, lb) do\n" <>
          "      {_cp, size} -> {:ok, %{state | cursor: c - size}}\n" <>
          "      :error -> {:fail, state}\n" <>
          "    end\n" <>
          "  end\n\n")

    case parts do
      [] -> ""
      _ -> "  # Snowball runtime helpers.\n" <> IO.iodata_to_binary(parts)
    end
  end

  defp maybe_emit(acc, true, code), do: acc ++ [code]
  defp maybe_emit(acc, false, _code), do: acc

  # -----------------------------------------------------------------------
  # Routine generation
  # -----------------------------------------------------------------------

  defp emit_routines(program, ctx) do
    Enum.map_join(program.defs, "", fn
      %{kind: :define_routine, name: name, body: body} ->
        mode = routine_mode(program, name)
        emit_routine(name, body, mode, ctx)

      %{kind: :define_grouping} ->
        ""
    end)
  end

  defp routine_mode(program, name) do
    case Map.get(program.symbols, name) do
      %{mode: :backward} -> :backward
      _ -> :forward
    end
  end

  defp emit_routine(name, body, mode, ctx) do
    body_code = compile_command(body, mode, ctx, "    ")

    "  defp r_#{name}(%Stemmer{} = state) do\n" <>
      body_code <> "\n" <>
      "  end\n\n"
  end

  # -----------------------------------------------------------------------
  # Command compiler
  # -----------------------------------------------------------------------

  # All compile_command handlers use string concatenation (no heredocs) to
  # avoid the Elixir heredoc `\` + `"""` parsing bug.

  defp compile_command(node, mode, ctx, i) do
    case node do
      %{kind: :seq, body: cmds} ->
        compile_seq(cmds, mode, ctx, i)

      %{kind: :do, body: body} ->
        inner = compile_command(body, mode, ctx, i <> "  ")
        # Forward do: always restores absolute cursor (ref C: int V=z->c; ... z->c=V).
        # Backward do: always restores relative cursor (ref C: int V=z->l-z->c; ... z->c=z->l-V).
        do_fn = if mode == :backward, do: "snowball_do_b", else: "snowball_do_f"
        "{:ok, #{do_fn}(state, fn state ->\n" <>
          inner <> "\n" <>
          i <> "end)}"
        |> prefix(i)

      %{kind: :try, body: body} ->
        inner = compile_command(body, mode, ctx, i <> "  ")
        "{:ok, snowball_try(state, fn state ->\n" <>
          inner <> "\n" <>
          i <> "end)}"
        |> prefix(i)

      %{kind: :not, body: body} ->
        # Snowball `not C` is a boolean complement with cursor-restore semantics
        # (mirrors the C runtime: `int c = z->c; result = C(z); z->c = c; return !result`).
        # Only the cursor is restored; string modifications and other state changes
        # made by C are preserved (e.g. `not pronoun` in Esperanto deletes the
        # accusative -n suffix even though `not` ultimately fails the block).
        inner = compile_command(body, mode, ctx, i <> "  ")
        i <> "(fn state ->\n" <>
          i <> "  saved_c = state.cursor\n" <>
          i <> "  case (fn state ->\n" <>
          inner <> "\n" <>
          i <> "  end).(state) do\n" <>
          i <> "    {:ok, s} -> {:fail, %{s | cursor: saved_c}}\n" <>
          i <> "    {:fail, s} -> {:ok, %{s | cursor: saved_c}}\n" <>
          i <> "  end\n" <>
          i <> "end).(state)"

      %{kind: :test, body: body} ->
        inner = compile_command(body, mode, ctx, i <> "  ")
        # Forward test: restore cursor on success but preserve variable changes (ref C: int V=z->c; ... z->c=V).
        # Backward test: restore relative cursor on success.
        test_fn = if mode == :backward, do: "snowball_test_b", else: "snowball_test_f"
        (i <> "#{test_fn}(state, fn state ->\n" <>
          inner <> "\n" <>
          i <> "end)")

      %{kind: :fail, body: body} ->
        inner = compile_command(body, mode, ctx, i <> "  ")
        fail_tail = if always_succeeds?(body), do: "", else: i <> "  r -> r\n"
        i <> "case (fn state ->\n" <>
          inner <> "\n" <>
          i <> "end).(state) do\n" <>
          i <> "  {:ok, s} -> {:fail, s}\n" <>
          fail_tail <>
          i <> "end"

      %{kind: :repeat, body: body} ->
        compile_repeat(body, mode, ctx, i)

      %{kind: :or, left: %{kind: :slice_among, among: among_node, restrictions: restrictions}, right: right} ->
        compile_or_slice_among(among_node, restrictions, right, mode, ctx, i)

      %{kind: :or, left: left, right: right} ->
        l_inner = compile_command(left, mode, ctx, i <> "    ")
        r_inner = compile_command(right, mode, ctx, i <> "    ")
        i <> "snowball_or(state,\n" <>
          i <> "  fn state ->\n" <>
          l_inner <> "\n" <>
          i <> "  end,\n" <>
          i <> "  fn state ->\n" <>
          r_inner <> "\n" <>
          i <> "  end)"

      %{kind: :and, left: left, right: right} ->
        # Snowball `A and B` = test(A), B — run A, restore cursor on success, then run B.
        # Mirrors `v_N = limit - cursor; A; cursor = limit - v_N; B` in the C/Python reference.
        test_node = %{kind: :test, body: left, line: Map.get(left, :line, 0)}
        compile_seq([test_node, right], mode, ctx, i)

      %{kind: :backwards, body: body} ->
        inner = compile_command(body, :backward, ctx, i <> "    ")
        # Reference C: z->lb = z->c; z->c = z->l; (body); z->c = z->lb;
        # Save cursor into limit_backward (as lb), set cursor to limit for backward scan.
        # After the body (success or fail), restore cursor to the saved value.
        i <> "(fn state ->\n" <>
          i <> "  old_cursor = state.cursor\n" <>
          i <> "  old_lb = state.limit_backward\n" <>
          i <> "  state = %{state | cursor: state.limit, limit_backward: old_cursor}\n" <>
          i <> "  {tag, s} = (fn state ->\n" <>
          inner <> "\n" <>
          i <> "  end).(state)\n" <>
          i <> "  {tag, %{s | cursor: old_cursor, limit_backward: old_lb}}\n" <>
          i <> "end).(state)"

      %{kind: :goto, body: body} ->
        compile_goto(body, mode, ctx, i)

      %{kind: :gopast, body: body} ->
        compile_gopast(body, mode, ctx, i)

      %{kind: :goto_grouping, grouping: g} ->
        sfx = mode_suffix(mode)
        i <> "lift(state, Stemmer.go_out_grouping#{sfx}(state, @g_#{g}))"

      %{kind: :gopast_grouping, grouping: g} ->
        sfx = mode_suffix(mode)
        adv = advance_fn(mode)
        i <> "case Stemmer.go_out_grouping#{sfx}(state, @g_#{g}) do\n" <>
          i <> "  :fail -> {:fail, state}\n" <>
          i <> "  %Stemmer{} = s -> #{adv}(s)\n" <>
          i <> "end"

      %{kind: :goto_non, grouping: g} ->
        sfx = mode_suffix(mode)
        i <> "lift(state, Stemmer.go_in_grouping#{sfx}(state, @g_#{g}))"

      %{kind: :gopast_non, grouping: g} ->
        sfx = mode_suffix(mode)
        adv = advance_fn(mode)
        i <> "case Stemmer.go_in_grouping#{sfx}(state, @g_#{g}) do\n" <>
          i <> "  :fail -> {:fail, state}\n" <>
          i <> "  %Stemmer{} = s -> #{adv}(s)\n" <>
          i <> "end"

      %{kind: :in_grouping, grouping: g} ->
        sfx = mode_suffix(mode)
        i <> "lift(state, Stemmer.in_grouping#{sfx}(state, @g_#{g}))"

      %{kind: :out_grouping, grouping: g} ->
        sfx = mode_suffix(mode)
        i <> "lift(state, Stemmer.out_grouping#{sfx}(state, @g_#{g}))"

      %{kind: :leftslice} ->
        # Forward: [ marks bra (lower, left end).
        # Backward: [ marks ket (higher, right end — cursor is scanning downward).
        field = if mode == :backward, do: "ket", else: "bra"
        i <> "{:ok, %{state | #{field}: state.cursor}}"

      %{kind: :rightslice} ->
        # Forward: ] marks ket (higher, right end).
        # Backward: ] marks bra (lower, left end — cursor has retreated).
        field = if mode == :backward, do: "bra", else: "ket"
        i <> "{:ok, %{state | #{field}: state.cursor}}"

      %{kind: :slicefrom, arg: {:literal, s}} ->
        i <> "{:ok, Stemmer.slice_from(state, #{inspect(s)})}"

      %{kind: :slicefrom, arg: {:var, v}} ->
        i <> "{:ok, Stemmer.slice_from(state, state.vars[#{var_atom(v)}])}"

      %{kind: :delete} ->
        i <> "{:ok, Stemmer.slice_del(state)}"

      %{kind: :attach, arg: {:literal, s}} ->
        # `attach S` (also written `<+ S`) inserts S at the current cursor
        # position and advances the cursor past S in both forward and backward
        # mode.  This is the key difference from `insert`, which restores
        # cursor.  After insertion the new characters are visible to subsequent
        # backward operations (e.g. palatalise_e in Czech).
        i <> "(fn ->\n" <>
          i <> "  saved_c = state.cursor\n" <>
          i <> "  new_state = Stemmer.insert(state, saved_c, saved_c, #{inspect(s)})\n" <>
          i <> "  {:ok, %{new_state | cursor: saved_c + byte_size(#{inspect(s)})}}\n" <>
          i <> "end).()"

      %{kind: :insert, arg: {:literal, s}} ->
        # `insert S` always inserts at cursor (bra=ket=cursor) and restores
        # cursor after insertion — this is canonical Snowball behaviour.
        i <> "(fn ->\n" <>
          i <> "  saved_c = state.cursor\n" <>
          i <> "  {:ok, %{Stemmer.insert(state, state.cursor, state.cursor, #{inspect(s)}) | cursor: saved_c}}\n" <>
          i <> "end).()"

      %{kind: :insert, arg: {:var, v}} ->
        # `insert VAR` inserts the string variable's value at cursor and
        # restores cursor — same semantics as the literal form.
        i <> "(fn ->\n" <>
          i <> "  saved_c = state.cursor\n" <>
          i <> "  {:ok, %{Stemmer.insert(state, state.cursor, state.cursor, state.vars[#{var_atom(v)}]) | cursor: saved_c}}\n" <>
          i <> "end).()"

      %{kind: :attach, arg: {:var, v}} ->
        # `attach VAR` inserts the string variable's value at cursor and
        # advances cursor past it — same semantics as the literal form.
        i <> "(fn ->\n" <>
          i <> "  saved_c = state.cursor\n" <>
          i <> "  val = state.vars[#{var_atom(v)}]\n" <>
          i <> "  new_state = Stemmer.insert(state, saved_c, saved_c, val)\n" <>
          i <> "  {:ok, %{new_state | cursor: saved_c + byte_size(val)}}\n" <>
          i <> "end).()"

      %{kind: :sliceto, var: v} ->
        i <> "{:ok, put_in(state.vars[#{var_atom(v)}], Stemmer.slice_to(state))}"

      %{kind: :next} ->
        adv = advance_fn(mode)
        i <> "#{adv}(state)"

      %{kind: :hop, count: count_ae} ->
        count_code = compile_ae(count_ae)
        adv = advance_fn(mode)
        i <> "(fn ->\n" <>
          i <> "  n = #{count_code}\n" <>
          i <> "  Enum.reduce_while(1..max(n, 0)//1, {:ok, state}, fn _, {:ok, s} ->\n" <>
          i <> "    case #{adv}(s) do\n" <>
          i <> "      {:ok, s2} -> {:cont, {:ok, s2}}\n" <>
          i <> "      {:fail, _} -> {:halt, {:fail, state}}\n" <>
          i <> "    end\n" <>
          i <> "  end)\n" <>
          i <> "end).()"

      %{kind: :atlimit} ->
        case mode do
          :backward -> i <> "if state.cursor <= state.limit_backward, do: {:ok, state}, else: {:fail, state}"
          _ -> i <> "if state.cursor >= state.limit, do: {:ok, state}, else: {:fail, state}"
        end

      %{kind: :tolimit} ->
        case mode do
          :backward -> i <> "{:ok, %{state | cursor: state.limit_backward}}"
          _ -> i <> "{:ok, %{state | cursor: state.limit}}"
        end

      %{kind: :tomark, ae: ae} ->
        code = compile_ae(ae)
        i <> "(fn ->\n" <>
          i <> "  target = #{code}\n" <>
          i <> "  if target < state.limit_backward or target > state.limit do\n" <>
          i <> "    {:fail, state}\n" <>
          i <> "  else\n" <>
          i <> "    {:ok, %{state | cursor: target}}\n" <>
          i <> "  end\n" <>
          i <> "end).()"

      %{kind: :atmark, ae: ae} ->
        code = compile_ae(ae)
        i <> "if state.cursor == #{code}, do: {:ok, state}, else: {:fail, state}"

      %{kind: :setmark, var: v} ->
        i <> "{:ok, put_in(state.vars[#{var_atom(v)}], state.cursor)}"

      %{kind: :set, var: v} ->
        i <> "{:ok, put_in(state.vars[#{var_atom(v)}], true)}"

      %{kind: :unset, var: v} ->
        i <> "{:ok, put_in(state.vars[#{var_atom(v)}], false)}"

      %{kind: :booltest, var: v} ->
        i <> "if state.vars[#{var_atom(v)}], do: {:ok, state}, else: {:fail, state}"

      %{kind: :true} ->
        i <> "{:ok, state}"

      %{kind: :false} ->
        i <> "{:fail, state}"

      %{kind: :eq_s} ->
        sfx = mode_suffix(mode)
        s = node.string
        i <> "lift(state, Stemmer.eq_s#{sfx}(state, #{inspect(s)}))"

      %{kind: :eq_s_var} ->
        sfx = mode_suffix(mode)
        var = node.var
        i <> "lift(state, Stemmer.eq_s#{sfx}(state, state.vars[#{var_atom(var)}]))"

      %{kind: :substring} ->
        # Bare `substring` (without enclosing `[` / `]`) is a compile-time
        # directive that switches the following `among` to substring-search
        # mode.  It has no runtime effect on ket or the cursor — the `[`
        # (leftslice) is what sets ket, not `substring` itself.  Any
        # `[substring] among(...)` pattern has already been converted to a
        # :slice_among node by transform_slice_among, so remaining bare
        # :substring nodes in the generated seq are genuinely no-ops.
        i <> "{:ok, state}"

      %{kind: :among} ->
        compile_among(node, mode, ctx, i)

      %{kind: :slice_among, among: among_node, restrictions: restrictions} ->
        compile_slice_among(among_node, restrictions, mode, ctx, i)

      %{kind: :restricted_among, among: among_node, restrictions: restrictions} ->
        compile_restricted_among(among_node, restrictions, mode, ctx, i)

      %{kind: :setlimit_slice_among, limit_cmd: limit_cmd, among: among_node, restrictions: restrictions} ->
        compile_setlimit_slice_among(limit_cmd, among_node, restrictions, mode, ctx, i)

      %{kind: :test_among, among: among_node} ->
        compile_test_among(among_node, mode, ctx, i)

      %{kind: :call, routine: name} ->
        i <> "r_#{name}(state)"

      %{kind: :dollar, var: v, op: op, rhs: rhs} ->
        compile_dollar(v, op, rhs, i)

      %{kind: :int_test, lhs: lhs, op: op, rhs: rhs} ->
        l_code = compile_ae(lhs)
        r_code = compile_ae(rhs)
        op_code = rel_op_to_elixir(op)
        i <> "if #{l_code} #{op_code} #{r_code}, do: {:ok, state}, else: {:fail, state}"

      %{kind: :setlimit, limit_cmd: limit_cmd, body: body} ->
        compile_setlimit(limit_cmd, body, mode, ctx, i)

      %{kind: :loop, count: count_ae, body: body} ->
        compile_loop(count_ae, body, mode, ctx, i)

      %{kind: :atleast, count: count_ae, body: body} ->
        compile_atleast(count_ae, body, mode, ctx, i)

      _ ->
        i <> "# TODO: unimplemented #{node[:kind]}\n" <>
          i <> "{:ok, state}"
    end
  end

  # Add indent prefix only if the string doesn't already start with it.
  defp prefix(code, i) do
    if String.starts_with?(code, i), do: code, else: i <> code
  end

  # -----------------------------------------------------------------------
  # Sequence
  # -----------------------------------------------------------------------

  # Returns true when the given AST node is guaranteed to always return
  # {:ok, state} — i.e. it cannot fail.  Used by compile_seq to omit the
  # dead `r -> r` fallthrough arm in the generated case expression, which
  # would otherwise trigger Dialyzer `pattern_match_cov` warnings.
  defp always_succeeds?(%{kind: :do}), do: true
  defp always_succeeds?(%{kind: :try}), do: true
  defp always_succeeds?(%{kind: :set}), do: true
  defp always_succeeds?(%{kind: :unset}), do: true
  defp always_succeeds?(%{kind: :setmark}), do: true
  defp always_succeeds?(%{kind: :sliceto}), do: true
  defp always_succeeds?(%{kind: :slicefrom}), do: true
  defp always_succeeds?(%{kind: :delete}), do: true
  defp always_succeeds?(%{kind: :insert}), do: true
  defp always_succeeds?(%{kind: :attach}), do: true
  defp always_succeeds?(%{kind: :leftslice}), do: true
  defp always_succeeds?(%{kind: :rightslice}), do: true
  defp always_succeeds?(%{kind: :substring}), do: true
  defp always_succeeds?(%{kind: :true}), do: true
  defp always_succeeds?(%{kind: :repeat}), do: true
  defp always_succeeds?(%{kind: :tolimit}), do: true
  defp always_succeeds?(%{kind: :dollar, op: :assign}), do: true
  defp always_succeeds?(%{kind: :dollar, op: :plus_assign}), do: true
  defp always_succeeds?(%{kind: :dollar, op: :minus_assign}), do: true
  defp always_succeeds?(%{kind: :dollar, op: :multiply_assign}), do: true
  defp always_succeeds?(%{kind: :dollar, op: :divide_assign}), do: true
  defp always_succeeds?(%{kind: :backwards, body: body}), do: always_succeeds?(body)
  defp always_succeeds?(%{kind: :seq, body: body}), do: Enum.all?(body, &always_succeeds?/1)
  defp always_succeeds?(_), do: false

  defp compile_seq([], _mode, _ctx, i), do: i <> "{:ok, state}"

  defp compile_seq([single], mode, ctx, i) do
    compile_command(single, mode, ctx, i)
  end

  defp compile_seq([first | rest], mode, ctx, i) do
    first_code = compile_command(first, mode, ctx, i <> "  ")
    rest_code = compile_seq(rest, mode, ctx, i <> "  ")

    tail =
      if always_succeeds?(first) do
        "\n" <> i <> "end"
      else
        "\n" <> i <> "  r -> r\n" <> i <> "end"
      end

    i <> "case (fn state ->\n" <>
      first_code <> "\n" <>
      i <> "end).(state) do\n" <>
      i <> "  {:ok, state} ->\n" <>
      rest_code <>
      tail
  end

  # -----------------------------------------------------------------------
  # Repeat
  # -----------------------------------------------------------------------

  # Optimised path: `repeat( ([substring] among(...)) or next )` in forward mode,
  # where the among has only single-codepoint entries with delete/slicefrom/no-op
  # actions.  Replaces the per-character binary-search loop with a single-pass
  # O(n) scan using a precomputed `%{codepoint => replacement}` module attribute.
  defp compile_repeat(
         %{
           kind: :or,
           left: %{kind: :slice_among, among: among_node, restrictions: []},
           right: %{kind: :next}
         } = body,
         :forward,
         ctx,
         i
       ) do
    case find_scan_idx(among_node, :forward, ctx) do
      nil -> compile_repeat_loop(body, :forward, ctx, i)
      idx -> i <> "{:ok, Stemmer.scan_and_replace_forward(state, @scan_#{idx})}"
    end
  end

  # Seq-wrapped form: `or(seq([slice_among]), next)` — the `( [substring] among(...) )`
  # parentheses in the source produce a single-element :seq around the slice_among.
  defp compile_repeat(
         %{
           kind: :or,
           left: %{kind: :seq, body: [%{kind: :slice_among, among: among_node, restrictions: []}]},
           right: %{kind: :next}
         } = body,
         :forward,
         ctx,
         i
       ) do
    case find_scan_idx(among_node, :forward, ctx) do
      nil -> compile_repeat_loop(body, :forward, ctx, i)
      idx -> i <> "{:ok, Stemmer.scan_and_replace_forward(state, @scan_#{idx})}"
    end
  end

  defp compile_repeat(body, mode, ctx, i), do: compile_repeat_loop(body, mode, ctx, i)

  defp compile_repeat_loop(body, mode, ctx, i) do
    inner = compile_command(body, mode, ctx, i <> "    ")

    # Snowball `repeat` semantics: execute body until it fails.  On failure,
    # the cursor is restored to the position it had at the START of that
    # iteration, but any string modifications made by the body (slice
    # operations that changed `current` / `limit`) are kept.  We therefore
    # return `{:ok, %{s | cursor: state.cursor}}` rather than `{:ok, state}`,
    # preserving string changes while restoring the cursor.
    i <> "(fn loop_fn ->\n" <>
      i <> "  loop_fn.(loop_fn, state)\n" <>
      i <> "end).(fn loop_fn, state ->\n" <>
      i <> "  case (fn state ->\n" <>
      inner <> "\n" <>
      i <> "  end).(state) do\n" <>
      i <> "    {:ok, s} -> loop_fn.(loop_fn, s)\n" <>
      i <> "    {:fail, s} -> {:ok, %{s | cursor: state.cursor}}\n" <>
      i <> "  end\n" <>
      i <> "end)"
  end

  defp find_scan_idx(among_node, mode, ctx) do
    Enum.find_value(ctx.scan_maps, fn {{node, m}, idx} ->
      if node == among_node and m == mode, do: idx, else: nil
    end)
  end

  # -----------------------------------------------------------------------
  # goto / gopast generic (non-grouping)
  # -----------------------------------------------------------------------

  # goto C: find position where C succeeds; cursor left at BEFORE C's match.
  defp compile_goto(body, mode, ctx, i) do
    inner = compile_command(body, mode, ctx, i <> "    ")
    adv = advance_fn(mode)

    i <> "(fn loop_fn ->\n" <>
      i <> "  loop_fn.(loop_fn, state)\n" <>
      i <> "end).(fn loop_fn, state ->\n" <>
      i <> "  v = state.cursor\n" <>
      i <> "  case (fn state ->\n" <>
      inner <> "\n" <>
      i <> "  end).(state) do\n" <>
      i <> "    {:ok, s} -> {:ok, %{s | cursor: v}}\n" <>
      i <> "    {:fail, _} ->\n" <>
      i <> "      case #{adv}(%{state | cursor: v}) do\n" <>
      i <> "        {:ok, s} -> loop_fn.(loop_fn, s)\n" <>
      i <> "        {:fail, _} -> {:fail, state}\n" <>
      i <> "      end\n" <>
      i <> "  end\n" <>
      i <> "end)"
  end

  # gopast C: find position where C succeeds; cursor left AFTER C's match.
  defp compile_gopast(body, mode, ctx, i) do
    inner = compile_command(body, mode, ctx, i <> "    ")
    adv = advance_fn(mode)

    i <> "(fn loop_fn ->\n" <>
      i <> "  loop_fn.(loop_fn, state)\n" <>
      i <> "end).(fn loop_fn, state ->\n" <>
      i <> "  v = state.cursor\n" <>
      i <> "  case (fn state ->\n" <>
      inner <> "\n" <>
      i <> "  end).(state) do\n" <>
      i <> "    {:ok, s} -> {:ok, s}\n" <>
      i <> "    {:fail, _} ->\n" <>
      i <> "      case #{adv}(%{state | cursor: v}) do\n" <>
      i <> "        {:ok, s} -> loop_fn.(loop_fn, s)\n" <>
      i <> "        {:fail, _} -> {:fail, state}\n" <>
      i <> "      end\n" <>
      i <> "  end\n" <>
      i <> "end)"
  end

  # -----------------------------------------------------------------------
  # setlimit
  # -----------------------------------------------------------------------

  defp compile_setlimit(limit_cmd, body, mode, ctx, i) do
    limit_code = compile_command(limit_cmd, mode, ctx, i <> "    ")
    body_code = compile_command(body, mode, ctx, i <> "    ")
    # In forward mode the working ceiling is `limit`; in backward mode it is `limit_backward`.
    {saved_var, limit_field} =
      if mode == :backward,
        do: {"old_lb", "limit_backward"},
        else: {"old_lim", "limit"}

    # Only emit the {:fail, s} arm when the body can actually fail; when the
    # body always succeeds, Dialyzer would flag the arm as unreachable.
    fail_arm =
      if always_succeeds?(body),
        do: "",
        else: i <> "        {:fail, s} -> {:fail, %{s | #{limit_field}: #{saved_var}}}\n"

    i <> "(fn ->\n" <>
      i <> "  case (fn state ->\n" <>
      limit_code <> "\n" <>
      i <> "  end).(state) do\n" <>
      i <> "    {:fail, _} -> {:fail, state}\n" <>
      i <> "    {:ok, limit_state} ->\n" <>
      i <> "      #{saved_var} = state.#{limit_field}\n" <>
      # Reference C: after limit cmd, cursor is restored to its pre-cmd position;
      # only the limit field (lb or limit) is updated from where the limit cmd left cursor.
      i <> "      state = %{state | #{limit_field}: limit_state.cursor}\n" <>
      i <> "      case (fn state ->\n" <>
      body_code <> "\n" <>
      i <> "      end).(state) do\n" <>
      i <> "        {:ok, s} -> {:ok, %{s | #{limit_field}: #{saved_var}}}\n" <>
      fail_arm <>
      i <> "      end\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end

  # -----------------------------------------------------------------------
  # loop / atleast
  # -----------------------------------------------------------------------

  defp compile_loop(count_ae, body, mode, ctx, i) do
    count_code = compile_ae(count_ae)
    inner = compile_command(body, mode, ctx, i <> "    ")

    i <> "(fn ->\n" <>
      i <> "  n = #{count_code}\n" <>
      i <> "  Enum.reduce_while(1..max(n, 0)//1, {:ok, state}, fn _, {:ok, s} ->\n" <>
      i <> "    case (fn state ->\n" <>
      inner <> "\n" <>
      i <> "    end).(s) do\n" <>
      i <> "      {:ok, s2} -> {:cont, {:ok, s2}}\n" <>
      i <> "      {:fail, s2} -> {:halt, {:fail, s2}}\n" <>
      i <> "    end\n" <>
      i <> "  end)\n" <>
      i <> "end).()"
  end

  defp compile_atleast(count_ae, body, mode, ctx, i) do
    count_code = compile_ae(count_ae)
    inner = compile_command(body, mode, ctx, i <> "    ")
    repeat_inner = compile_command(body, mode, ctx, i <> "      ")

    i <> "(fn ->\n" <>
      i <> "  n = #{count_code}\n" <>
      i <> "  case Enum.reduce_while(1..max(n, 0)//1, {:ok, state}, fn _, {:ok, s} ->\n" <>
      i <> "    case (fn state ->\n" <>
      inner <> "\n" <>
      i <> "    end).(s) do\n" <>
      i <> "      {:ok, s2} -> {:cont, {:ok, s2}}\n" <>
      i <> "      {:fail, s2} -> {:halt, {:fail, s2}}\n" <>
      i <> "    end\n" <>
      i <> "  end) do\n" <>
      i <> "    {:fail, s} -> {:fail, s}\n" <>
      i <> "    {:ok, state} ->\n" <>
      i <> "      (fn loop_fn ->\n" <>
      i <> "        loop_fn.(loop_fn, state)\n" <>
      i <> "      end).(fn loop_fn, state ->\n" <>
      i <> "        case (fn state ->\n" <>
      repeat_inner <> "\n" <>
      i <> "        end).(state) do\n" <>
      i <> "          {:ok, s} -> loop_fn.(loop_fn, s)\n" <>
      i <> "          {:fail, _} -> {:ok, state}\n" <>
      i <> "        end\n" <>
      i <> "      end)\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end

  # -----------------------------------------------------------------------
  # Dollar ($) integer operations
  # -----------------------------------------------------------------------

  defp compile_dollar(v, :assign, rhs, i) do
    rhs_code = compile_ae(rhs)
    i <> "{:ok, put_in(state.vars[#{var_atom(v)}], #{rhs_code})}"
  end

  defp compile_dollar(v, op, rhs, i) when op in [:eq, :ne, :lt, :le, :gt, :ge] do
    l_code = "state.vars[#{var_atom(v)}]"
    r_code = compile_ae(rhs)
    op_code = rel_op_to_elixir(op)
    i <> "if #{l_code} #{op_code} #{r_code}, do: {:ok, state}, else: {:fail, state}"
  end

  defp compile_dollar(v, op, rhs, i) do
    rhs_code = compile_ae(rhs)
    op_code = assign_op_to_elixir(op)
    i <> "(fn ->\n" <>
      i <> "  new_val = state.vars[#{var_atom(v)}] #{op_code} #{rhs_code}\n" <>
      i <> "  {:ok, put_in(state.vars[#{var_atom(v)}], new_val)}\n" <>
      i <> "end).()"
  end

  # -----------------------------------------------------------------------
  # Among
  # -----------------------------------------------------------------------

  defp compile_among(%{kind: :among, entries: entries} = node, mode, ctx, i) do
    default_action = Map.get(node, :default_action)
    pre_constraint = Map.get(node, :pre_constraint)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == node and m == mode, do: j, else: nil
    end)
    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)

    tref = table_ref(idx, ctx)

    if result_count == 0 and is_nil(default_action) and is_nil(pre_constraint) do
      # No slice actions in this among — just advance the cursor without
      # touching bra/ket so that any explicit [ ] markers are preserved.
      i <> "(fn ->\n" <>
        i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
        i <> "    :fail -> {:fail, state}\n" <>
        i <> "    {%Stemmer{} = s, _} -> {:ok, s}\n" <>
        i <> "  end\n" <>
        i <> "end).()"
    else
      # Bare `among(...)` with actions does NOT set ket/bra — it deliberately
      # inherits slice markers from the enclosing context.  This is the Snowball
      # convention: `[substring] among(...)` (compiled as :slice_among) is what
      # sets ket/bra; a plain `among(...)` with actions relies on a preceding
      # `[substring]` step having already positioned the slice markers correctly.
      # (Example: Italian `attached_pronoun` uses a bare `among((RV) ...)` after
      # `[substring] among(pronoun list)` and intentionally reuses the pronoun's
      # ket/bra for the replacement, with `find_among_b` only verifying the verb form.)
      cases = build_among_cases(entries, mode, ctx, i, default_action)

      dispatch =
        i <> "      case result do\n" <>
          cases <> "\n" <>
          i <> "        _ -> {:ok, s}\n" <>
          i <> "      end"

      # When a pre_constraint is present (e.g. Italian's `(RV)` before any
      # strings), the Snowball C compiler applies it AFTER find_among but
      # BEFORE the case dispatch.  Wrap the dispatch in the constraint check.
      inner =
        if is_nil(pre_constraint) do
          dispatch
        else
          pc_code = compile_command(pre_constraint, mode, ctx, i <> "        ")

          fail_tail =
            if always_succeeds?(pre_constraint) do
              i <> "      end"
            else
              i <> "        r -> r\n" <> i <> "      end"
            end

          i <> "      case (fn state ->\n" <>
            pc_code <> "\n" <>
            i <> "      end).(state) do\n" <>
            i <> "        {:ok, state} ->\n" <>
            dispatch <> "\n" <>
            fail_tail
        end

      i <> "(fn ->\n" <>
        i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
        i <> "    :fail -> {:fail, state}\n" <>
        i <> "    {%Stemmer{} = s, result} ->\n" <>
        i <> "      state = s\n" <>
        inner <> "\n" <>
        i <> "  end\n" <>
        i <> "end).()"
    end
  end

  # `[substring] restriction... among(...)` — the correct code generation order
  # (matching the Snowball reference C compiler) is:
  #   1. ket = cursor  (from the `[` left bracket)
  #   2. find_among    (from `substring` — the search)
  #   3. bra = cursor  (from `]` — set AFTER cursor has been retreated)
  #   4. restriction checks (e.g. r_R1, r_R2) with the retreated cursor
  #   5. switch on result  (from among actions)
  defp compile_slice_among(%{kind: :among, entries: entries} = node, restrictions, mode, ctx, i) do
    default_action = Map.get(node, :default_action)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == node and m == mode, do: j, else: nil
    end)
    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)
    result_var = if result_count > 0 or not is_nil(default_action), do: "result", else: "_result"

    {ket_field, bra_field} =
      if mode == :backward, do: {"ket", "bra"}, else: {"bra", "ket"}

    # Build the action dispatch (executed after restrictions pass).
    action_body =
      if result_count > 0 or not is_nil(default_action) do
        cases = build_among_cases(entries, mode, ctx, i <> "        ", default_action)

        i <> "      case result do\n" <>
          cases <> "\n" <>
          i <> "        _ -> {:ok, state}\n" <>
          i <> "      end"
      else
        i <> "      {:ok, state}"
      end

    # Wrap action body in restriction check when there are restrictions.
    inner_body = wrap_restrictions(restrictions, action_body, mode, ctx, i)

    tref = table_ref(idx, ctx)

    i <> "(fn ->\n" <>
      i <> "  state = %{state | #{ket_field}: state.cursor}\n" <>
      i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
      i <> "    :fail -> {:fail, state}\n" <>
      i <> "    {%Stemmer{} = s, #{result_var}} ->\n" <>
      i <> "      state = %{s | #{bra_field}: s.cursor}\n" <>
      inner_body <> "\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end

  # Wrap an action body in a `case ... do {:ok, state} -> ...` block that
  # first runs the restriction sequence. When every restriction always
  # succeeds (e.g. a bare `[` or `]` cursor mark), the trailing `r -> r`
  # catch-all is omitted because dialyzer/the compiler would flag it as
  # unreachable.
  defp wrap_restrictions([], action_body, _mode, _ctx, _i), do: action_body

  defp wrap_restrictions(restrictions, action_body, mode, ctx, i) do
    restriction_code = compile_seq(restrictions, mode, ctx, i <> "        ")

    fail_tail =
      if Enum.all?(restrictions, &always_succeeds?/1) do
        i <> "      end"
      else
        i <> "        r -> r\n" <> i <> "      end"
      end

    i <> "      case (fn state ->\n" <>
      restriction_code <> "\n" <>
      i <> "      end).(state) do\n" <>
      i <> "        {:ok, state} ->\n" <>
      action_body <> "\n" <>
      fail_tail
  end

  # `substring restriction... among(...)` — bare `substring` (no enclosing
  # `[` / `]`).  The Snowball C compiler emits find_among FIRST, then applies
  # the restriction with the post-match cursor.  Neither ket nor bra are set by
  # this node — they are inherited from a preceding `[substring] among(...)`.
  # The restriction check (e.g. r_RV) uses the cursor position left by
  # find_among (i.e. the beginning of the matched verb ending), not the
  # cursor before the search.
  defp compile_restricted_among(%{kind: :among, entries: entries} = among_node, restrictions, mode, ctx, i) do
    default_action = Map.get(among_node, :default_action)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == among_node and m == mode, do: j, else: nil
    end)

    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)
    tref = table_ref(idx, ctx)
    result_var = if result_count > 0 or not is_nil(default_action), do: "result", else: "_result"

    action_body =
      if result_count > 0 or not is_nil(default_action) do
        cases = build_among_cases(entries, mode, ctx, i <> "        ", default_action)

        i <> "      case result do\n" <>
          cases <> "\n" <>
          i <> "        _ -> {:ok, state}\n" <>
          i <> "      end"
      else
        i <> "      {:ok, state}"
      end

    inner_body = wrap_restrictions(restrictions, action_body, mode, ctx, i)

    i <> "(fn ->\n" <>
      i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
      i <> "    :fail -> {:fail, state}\n" <>
      i <> "    {%Stemmer{} = s, #{result_var}} ->\n" <>
      i <> "      state = s\n" <>
      inner_body <> "\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end

  # `[substring] among(...) or (second_alt)` — like compile_slice_among but when
  # the first alternative fails (action returns :fail), the cursor is restored to
  # the position AFTER find_among (i.e. the beginning of the matched suffix, which
  # is what bra holds in backward mode / ket in forward mode), and the second
  # alternative is then tried from that position.  This matches the C/Python
  # reference semantics where the `or` saves cursor *after* find_among_b, not before.
  defp compile_or_slice_among(
         %{kind: :among, entries: entries} = among_node,
         restrictions,
         right,
         mode,
         ctx,
         i
       ) do
    default_action = Map.get(among_node, :default_action)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == among_node and m == mode, do: j, else: nil
    end)

    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)
    result_var = if result_count > 0 or not is_nil(default_action), do: "result", else: "_result"

    {ket_field, bra_field} =
      if mode == :backward, do: {"ket", "bra"}, else: {"bra", "ket"}

    action_body =
      if result_count > 0 or not is_nil(default_action) do
        cases = build_among_cases(entries, mode, ctx, i <> "        ", default_action)

        i <> "      case result do\n" <>
          cases <> "\n" <>
          i <> "        _ -> {:ok, state}\n" <>
          i <> "      end"
      else
        i <> "      {:ok, state}"
      end

    inner_body = wrap_restrictions(restrictions, action_body, mode, ctx, i)

    right_code = compile_command(right, mode, ctx, i <> "          ")
    tref = table_ref(idx, ctx)

    i <> "(fn ->\n" <>
      i <> "  state = %{state | #{ket_field}: state.cursor}\n" <>
      i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
      i <> "    :fail -> {:fail, state}\n" <>
      i <> "    {%Stemmer{} = s, #{result_var}} ->\n" <>
      i <> "      state = %{s | #{bra_field}: s.cursor}\n" <>
      i <> "      after_find_rel = state.limit - state.cursor\n" <>
      i <> "      case (fn state ->\n" <>
      inner_body <> "\n" <>
      i <> "      end).(state) do\n" <>
      i <> "        {:ok, s} -> {:ok, s}\n" <>
      i <> "        {:fail, s} ->\n" <>
      i <> "          state = %{s | cursor: s.limit - after_find_rel}\n" <>
      right_code <> "\n" <>
      i <> "      end\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end

  # `setlimit LIMIT for ([substring]) restriction... among(...)` — the Snowball C
  # compiler fuses the setlimit, ket-set, find_among and bra-set into one unit:
  #   1. save limit field (lb or limit)
  #   2. run limit_cmd to get the new limit position
  #   3. ket = cursor  (from the `[`)
  #   4. set limit field to new position
  #   5. find_among (the search is combined with substring)
  #   6. if no match: restore limit, fail
  #   7. bra = cursor  (AFTER find_among)
  #   8. restore limit field
  #   9. dispatch on result
  defp compile_setlimit_slice_among(limit_cmd, %{kind: :among, entries: entries} = among_node, restrictions, mode, ctx, i) do
    default_action = Map.get(among_node, :default_action)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == among_node and m == mode, do: j, else: nil
    end)

    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)
    result_var = if result_count > 0 or not is_nil(default_action), do: "result", else: "_result"

    {ket_field, bra_field, limit_field} =
      if mode == :backward,
        do: {"ket", "bra", "limit_backward"},
        else: {"bra", "ket", "limit"}

    limit_code = compile_command(limit_cmd, mode, ctx, i <> "    ")

    action_body =
      if result_count > 0 or not is_nil(default_action) do
        cases = build_among_cases(entries, mode, ctx, i <> "        ", default_action)

        i <> "      case result do\n" <>
          cases <> "\n" <>
          i <> "        _ -> {:ok, state}\n" <>
          i <> "      end"
      else
        i <> "      {:ok, state}"
      end

    inner_body = wrap_restrictions(restrictions, action_body, mode, ctx, i)

    tref = table_ref(idx, ctx)

    i <> "(fn ->\n" <>
      i <> "  old_limit = state.#{limit_field}\n" <>
      i <> "  case (fn state ->\n" <>
      limit_code <> "\n" <>
      i <> "  end).(state) do\n" <>
      i <> "    {:fail, _} -> {:fail, state}\n" <>
      i <> "    {:ok, limit_state} ->\n" <>
      i <> "      state = %{state | #{ket_field}: state.cursor, #{limit_field}: limit_state.cursor}\n" <>
      i <> "      case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
      i <> "        :fail -> {:fail, %{state | #{limit_field}: old_limit}}\n" <>
      i <> "        {%Stemmer{} = s, #{result_var}} ->\n" <>
      i <> "          state = %{s | #{bra_field}: s.cursor, #{limit_field}: old_limit}\n" <>
      inner_body <> "\n" <>
      i <> "      end\n" <>
      i <> "  end\n" <>
      i <> "end).()"
  end


  # `test substring among(...)` — cursor is saved before the search and
  # restored (unconditionally) before the action dispatch.  The bra marker
  # is NOT set from the match position here; each action sets its own
  # slice markers with explicit `[` / `]` operators.
  defp compile_test_among(%{kind: :among, entries: entries} = node, mode, ctx, i) do
    default_action = Map.get(node, :default_action)
    idx = Enum.find_value(ctx.amongs, 0, fn {{n, m}, j} ->
      if n == node and m == mode, do: j, else: nil
    end)
    {_flat, result_count} = flatten_among_entries(entries)
    sfx = mode_suffix(mode)
    tref = table_ref(idx, ctx)

    if result_count == 0 and is_nil(default_action) do
      i <> "(fn ->\n" <>
        i <> "  rel = state.limit - state.cursor\n" <>
        i <> "  state = %{state | ket: state.cursor}\n" <>
        i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
        i <> "    :fail -> {:fail, %{state | cursor: state.limit - rel}}\n" <>
        i <> "    {%Stemmer{} = s, _} -> {:ok, %{s | cursor: s.limit - rel}}\n" <>
        i <> "  end\n" <>
        i <> "end).()"
    else
      cases = build_among_cases(entries, mode, ctx, i, default_action)

      i <> "(fn ->\n" <>
        i <> "  rel = state.limit - state.cursor\n" <>
        i <> "  state = %{state | ket: state.cursor}\n" <>
        i <> "  case Stemmer.find_among#{sfx}(state, #{tref}) do\n" <>
        i <> "    :fail -> {:fail, %{state | cursor: state.limit - rel}}\n" <>
        i <> "    {%Stemmer{} = s, result} ->\n" <>
        i <> "      state = %{s | cursor: s.limit - rel}\n" <>
        i <> "      case result do\n" <>
        cases <> "\n" <>
        i <> "        _ -> {:ok, state}\n" <>
        i <> "      end\n" <>
        i <> "  end\n" <>
        i <> "end).()"
    end
  end

  defp build_among_cases(entries, mode, ctx, i, default_action) do
    if among_uses_methods?(entries) do
      # Method-in-find_among pattern: constraints were already called inside
      # find_among_b.  Every successful match returns result=1.  If there is
      # a shared default action (e.g. Lovins's `delete`), run it; otherwise
      # just report success (the action is outside the among, e.g. Hindi).
      if is_nil(default_action) do
        i <> "        1 ->\n" <> i <> "          {:ok, state}"
      else
        da_code = compile_command(default_action, mode, ctx, i <> "          ")
        i <> "        1 ->\n" <> da_code
      end
    else
      {result_map, _} =
        Enum.reduce(entries, {%{}, 1}, fn %{action: action}, {acc, n} ->
          case action do
            nil -> {acc, n}
            %{kind: :seq, body: []} -> {acc, n}
            _ -> if Map.has_key?(acc, n), do: {acc, n}, else: {Map.put(acc, n, action), n + 1}
          end
        end)

      result_map
      |> Enum.sort_by(fn {n, _} -> n end)
      |> Enum.map_join("\n", fn {n, action} ->
        case default_action do
          nil ->
            body = compile_command(action, mode, ctx, i <> "          ")
            i <> "        #{n} ->\n" <> body

          da ->
            # Chain: run the specific entry's action; if it succeeds, run the
            # default action (e.g. `delete` in Lovins).  This is the pattern
            # where a bare `(action)` with no preceding strings in an among
            # block acts as a shared post-action for all specific entries.
            action_code = compile_command(action, mode, ctx, i <> "              ")
            da_code = compile_command(da, mode, ctx, i <> "              ")

            i <> "        #{n} ->\n" <>
              i <> "          case (fn state ->\n" <>
              action_code <> "\n" <>
              i <> "          end).(state) do\n" <>
              i <> "            {:ok, state} ->\n" <>
              da_code <> "\n" <>
              i <> "            r -> r\n" <>
              i <> "          end"
        end
      end)
    end
  end

  # True when all entry actions are bare-name constraint calls (constraint: true)
  # or nil/empty-seq — the pure method-in-find_among pattern (Lovins, Hindi).
  defp among_uses_methods?(entries) do
    Enum.any?(entries, fn e -> match?(%{kind: :call, constraint: true}, e.action) end) and
      Enum.all?(entries, fn e ->
        case e.action do
          %{kind: :call, constraint: true} -> true
          nil -> true
          %{kind: :seq, body: []} -> true
          _ -> false
        end
      end)
  end

  # Returns the Elixir expression to reference an among table — either the
  # module attribute `@a_N` (for plain tables) or the function call `a_N()`
  # (for method tables that embed closures and therefore cannot be attributes).
  defp table_ref(idx, ctx) do
    if MapSet.member?(ctx.method_among_indices, idx), do: "a_#{idx}()", else: "@a_#{idx}"
  end

  # -----------------------------------------------------------------------
  # Arithmetic expression compiler
  # -----------------------------------------------------------------------

  defp compile_ae(node) do
    case node do
      %{kind: :integer_literal, value: n} -> to_string(n)
      %{kind: :cursor_ref} -> "state.cursor"
      %{kind: :limit_ref} -> "state.limit"
      %{kind: :size_ref} -> "byte_size(state.current)"
      %{kind: :len_ref} -> "Stemmer.codepoint_length(state.current)"
      %{kind: :maxint_ref} -> "9_007_199_254_740_991"
      %{kind: :minint_ref} -> "-9_007_199_254_740_991"
      %{kind: :var_ref, var: v} -> "state.vars[#{var_atom(v)}]"
      %{kind: :neg, operand: op} -> "-(#{compile_ae(op)})"
      %{kind: :plus, left: l, right: r} -> "(#{compile_ae(l)} + #{compile_ae(r)})"
      %{kind: :minus, left: l, right: r} -> "(#{compile_ae(l)} - #{compile_ae(r)})"
      %{kind: :multiply, left: l, right: r} -> "(#{compile_ae(l)} * #{compile_ae(r)})"
      %{kind: :divide, left: l, right: r} -> "div(#{compile_ae(l)}, #{compile_ae(r)})"
      %{kind: :sizeof, arg: {:literal, s}} -> to_string(byte_size(s))
      %{kind: :sizeof, arg: {:var, v}} -> "byte_size(state.#{v})"
      %{kind: :lenof, arg: {:literal, s}} -> to_string(length(String.codepoints(s)))
      %{kind: :lenof, arg: {:var, v}} -> "Stemmer.codepoint_length(state.#{v})"
      _ -> "0 # TODO: unknown AE #{node[:kind]}"
    end
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  defp mode_suffix(:backward), do: "_b"
  defp mode_suffix(_), do: ""

  defp advance_fn(:backward), do: "next_codepoint_b"
  defp advance_fn(_), do: "next_codepoint"

  defp var_atom(name), do: ":#{name}"

  defp assign_op_to_elixir(:plus_assign), do: "+"
  defp assign_op_to_elixir(:minus_assign), do: "-"
  defp assign_op_to_elixir(:multiply_assign), do: "*"
  defp assign_op_to_elixir(:divide_assign), do: "div"

  defp rel_op_to_elixir(:eq), do: "=="
  defp rel_op_to_elixir(:ne), do: "!="
  defp rel_op_to_elixir(:lt), do: "<"
  defp rel_op_to_elixir(:le), do: "<="
  defp rel_op_to_elixir(:gt), do: ">"
  defp rel_op_to_elixir(:ge), do: ">="
end
