# Snowball

Snowball string-processing language compiler and runtime for Elixir.

[Snowball](https://snowballstem.org) is a small string-processing language designed for creating stemming algorithms in information retrieval. This package compiles `.sbl` source files into Elixir modules and provides the runtime support functions that the generated modules call into.

This package does **not** bundle pre-compiled stemmers. For the canonical Snowball algorithms compiled to Elixir modules (English, French, German, and 30+ more), see the companion [`text_stemmer`](https://hex.pm/packages/text_stemmer) package.

## What's in the box

* `Snowball.Lexer`, `Snowball.Preprocessor`, `Snowball.Analyser`, `Snowball.Generator` — the four stages of the compiler pipeline.

* `Snowball.Stemmer` — the runtime helpers (string buffer state, character class membership, `find_among` dispatch tables, etc.) that every generated stemmer module calls into.

* `mix snowball.gen` — Mix task that walks a directory of `.sbl` sources, runs each through the pipeline, and writes generated `.ex` files to disk.

## Installation

Add `:snowball` to your `mix.exs` deps:

```elixir
def deps do
  [
    {:snowball, "~> 0.1"}
  ]
end
```

## Generating stemmers from `.sbl` sources

Drop your Snowball sources in `src/algorithms/` and run:

```bash
mix snowball.gen
```

By default this generates `Snowball.Stemmers.<Lang>` modules into `lib/snowball/stemmers/`. Override either with the relevant flag:

```bash
mix snowball.gen --module-prefix MyApp.Stemmers \
                 --output-dir lib/my_app/stemmers \
                 --algorithms-dir priv/snowball
```

You can also generate a specific algorithm by name:

```bash
mix snowball.gen english french
```

The generated modules depend only on `Snowball.Stemmer` for their runtime, so adding `:snowball` to your deps is sufficient.

## Documentation

Full API documentation is published at [https://hexdocs.pm/snowball](https://hexdocs.pm/snowball).

## License

Apache-2.0. See [LICENSE.md](https://github.com/kipcole9/snowball/blob/v0.1.0/LICENSE.md).
