defmodule Snowball do
  @moduledoc """
  Snowball string-processing language compiler and runtime for Elixir.

  [Snowball](https://snowballstem.org) is a small string-processing language
  designed for creating stemming algorithms in information retrieval. This
  package provides:

  * a compiler pipeline that parses `.sbl` source files and emits Elixir
    modules implementing the described stemmer (`Snowball.Lexer`,
    `Snowball.Preprocessor`, `Snowball.Analyser`, `Snowball.Generator`),

  * the `mix snowball.gen` Mix task that drives the pipeline over a
    directory of `.sbl` files, and

  * the `Snowball.Runtime` runtime support module that generated stemmer
    modules call into at run time (string buffer manipulation, character
    classes, `find_among` dispatch tables, and so on).

  This package does **not** ship any pre-compiled stemmers itself. For
  the canonical Snowball algorithms compiled to Elixir modules, see the
  companion [`text_stemmer`](https://hex.pm/packages/text_stemmer) package.

  ## Generating a stemmer

      mix snowball.gen --module-prefix MyApp.Stemmers \\
                       --output-dir lib/my_app/stemmers \\
                       --algorithms-dir priv/snowball

  See `Mix.Tasks.Snowball.Gen` for the full set of options.

  """
end
