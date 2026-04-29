defmodule Snowball.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/kipcole9/snowball"

  def project do
    [
      app: :snowball,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      package: package(),
      docs: docs(),
      description: description(),
      source_url: @source_url,
      dialyzer: [
        plt_add_apps: [:mix, :ex_unit],
        flags: [:no_opaque]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:nimble_parsec, "~> 1.4", runtime: false},
      {:ex_doc, "~> 0.34", only: [:dev, :release], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Snowball string-processing language compiler and runtime for Elixir. " <>
      "Compiles `.sbl` files into Elixir modules and provides the runtime " <>
      "support functions those generated modules call into."
  end

  defp package do
    [
      maintainers: ["Kip Cole"],
      licenses: ["Apache-2.0"],
      links: links(),
      files: [
        "lib",
        "mix.exs",
        "README.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ]
    ]
  end

  def links do
    %{
      "GitHub" => @source_url,
      "Readme" => "#{@source_url}/blob/v#{@version}/README.md",
      "Changelog" => "#{@source_url}/blob/v#{@version}/CHANGELOG.md"
    }
  end

  defp docs do
    [
      main: "Snowball",
      source_ref: "v#{@version}",
      formatters: ["html", "markdown"],
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end
end
