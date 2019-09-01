# Snowball

Compiles Snowball files into Elixir. [Snowball](http://snowballstem.org/) is a language used for language stemming.  This project also generates stemmers from the Snowball programs in the Snowball repository.

Snowball source files have an `.sbl` suffix and are expected to be found in the `./src` directory which is examined recursively.

## Installation

The package can be installed by adding `snowball` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:snowball, "~> 0.1.0"}
  ]
end
```

The docs can be found at [https://hexdocs.pm/snowball](https://hexdocs.pm/snowball).

