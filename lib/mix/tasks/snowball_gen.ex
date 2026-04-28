defmodule Mix.Tasks.Snowball.Gen do
  @moduledoc """
  Generate Elixir stemmer modules from Snowball `.sbl` algorithm sources.

  Reads every `.sbl` file from the algorithms directory, runs it through the
  Snowball compiler pipeline (Lexer -> Analyser -> Generator), and writes
  the resulting Elixir source to the output directory.

  ## Usage

      mix snowball.gen                   # generate all algorithms
      mix snowball.gen english french    # generate specific algorithms

  ## Options

  * `--module-prefix` is the Elixir module prefix to use for generated
    stemmer modules. Defaults to `Snowball.Stemmers`. The full module name
    is the prefix joined with the PascalCase algorithm suffix (for example,
    `Text.Stemmer.Stemmers.DutchPorter`).

  * `--output-dir` is the directory into which generated `.ex` files are
    written. Defaults to `lib/snowball/stemmers`.

  * `--algorithms-dir` is the directory from which `.sbl` source files are
    read. Defaults to `src/algorithms`.

  ## Language name mapping

  The file stem (e.g. `dutch_porter`) becomes both the Elixir module
  suffix in PascalCase (`DutchPorter`) and the language atom passed to
  the generator (`:dutch_porter`).

  """

  use Mix.Task

  @shortdoc "Generate Elixir stemmers from Snowball .sbl sources"

  @default_algorithms_dir "src/algorithms"
  @default_output_dir "lib/snowball/stemmers"
  @default_module_prefix "Snowball.Stemmers"

  @switches [
    module_prefix: :string,
    output_dir: :string,
    algorithms_dir: :string
  ]

  @impl Mix.Task
  def run(args) do
    {options, langs_args} = OptionParser.parse!(args, strict: @switches)

    algorithms_dir = Keyword.get(options, :algorithms_dir, @default_algorithms_dir)
    output_dir = Keyword.get(options, :output_dir, @default_output_dir)

    module_prefix =
      options
      |> Keyword.get(:module_prefix, @default_module_prefix)
      |> resolve_prefix()

    File.mkdir_p!(output_dir)

    all_sbl =
      Path.wildcard(Path.join(algorithms_dir, "*.sbl"))
      |> Enum.sort()

    target_langs =
      case langs_args do
        [] -> Enum.map(all_sbl, &lang_name/1)
        langs -> langs
      end

    sbl_map = Map.new(all_sbl, fn path -> {lang_name(path), path} end)

    results =
      Enum.map(target_langs, fn lang ->
        case Map.fetch(sbl_map, lang) do
          {:ok, path} -> generate_one(lang, path, output_dir, module_prefix)
          :error -> {:error, lang, "no .sbl file found for #{lang}"}
        end
      end)

    ok_count = Enum.count(results, &match?({:ok, _}, &1))
    err_count = Enum.count(results, &match?({:error, _, _}, &1))

    Mix.shell().info("")
    Mix.shell().info("Generated: #{ok_count}  Errors: #{err_count}")

    if err_count > 0 do
      Mix.shell().error("\nFailed algorithms:")

      Enum.each(results, fn
        {:error, lang, reason} -> Mix.shell().error("  #{lang}: #{reason}")
        _ -> :ok
      end)

      Mix.raise("Generation had #{err_count} failure(s).")
    end
  end

  # -----------------------------------------------------------------------
  # Per-algorithm generation
  # -----------------------------------------------------------------------

  defp generate_one(lang, sbl_path, output_dir, module_prefix) do
    module_name = lang_to_module(lang, module_prefix)
    out_path = Path.join(output_dir, "#{lang}.ex")

    Mix.shell().info("  #{lang} -> #{out_path}")

    try do
      with {:read, {:ok, source}} <- {:read, File.read(sbl_path)},
           source = Snowball.Preprocessor.preprocess(source),
           {:lex, {:ok, tokens}} <- {:lex, Snowball.Lexer.tokenize(source)},
           {:analyse, {:ok, prog}} <- {:analyse, Snowball.Analyser.analyse(tokens)},
           src = Snowball.Generator.generate(prog, module_name, String.to_atom(lang)),
           {:write, :ok} <- {:write, File.write(out_path, src)} do
        {:ok, lang}
      else
        {:read, {:error, reason}} ->
          {:error, lang, "read failed: #{inspect(reason)}"}

        {:lex, {:error, reason, _rest, _line}} ->
          {:error, lang, "lexer error: #{inspect(reason)}"}

        {:analyse, {:error, reason}} ->
          {:error, lang, "analyser error: #{inspect(reason)}"}

        {:write, {:error, reason}} ->
          {:error, lang, "write failed: #{inspect(reason)}"}
      end
    rescue
      e -> {:error, lang, Exception.message(e)}
    end
  end

  # -----------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------

  @doc false
  def lang_name(sbl_path), do: Path.basename(sbl_path, ".sbl")

  @doc false
  def lang_to_module(lang, module_prefix \\ @default_module_prefix) do
    suffix =
      lang
      |> String.split("_")
      |> Enum.map_join(&String.capitalize/1)

    module_prefix
    |> resolve_prefix()
    |> Module.concat(String.to_atom(suffix))
  end

  defp resolve_prefix(prefix) when is_atom(prefix), do: prefix

  defp resolve_prefix(prefix) when is_binary(prefix) do
    prefix
    |> String.split(".")
    |> Enum.map(&String.to_atom/1)
    |> Module.concat()
  end
end
