defmodule EnsqTest.Mixfile do
  use Mix.Project

  def project do
    [app: :ensq,
     version: "0.1.6",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  def application do
    [applications: [:logger, :ensq]]
  end

  defp deps do
    [
      {:lager, "~> 2.1.1"},
      {:jsx, "~> 1.4.5"},
      {:jsxd, "~> 0.1.10"},
      {:goldrush, "~> 0.1.6"}
    ]
  end
end
