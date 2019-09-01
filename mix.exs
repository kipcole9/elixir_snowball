defmodule ElixirSnowball.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :snowball,
      version: @version,
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nimble_parsec, "~> 0.5"}
    ]
  end
end
