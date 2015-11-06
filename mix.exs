defmodule Ensq.Mixfile do
  use Mix.Project

  def project do
    [app: :ensq,
     version: "0.1.6",
     elixir: "~> 1.1",
     build_embedded: Mix.env == :prod,
     start_permanent: Mix.env == :prod,
     deps: deps]
  end

  defp deps do
    [
      {:lager, "~> 2.1.1"},
      {:jsx, "~> 1.4.5"},
      {:jsxd, "~> 0.1.10"},

      # Lager has a dependency on goldrush 0.1.6, but something is screwed up
      # where it tries to pull down 0.1.7 instead. Get around this by
      # hardcoding to a version in github. See this issue:
      # https://github.com/elixir-lang/elixir/issues/3872
      {:goldrush, git: "git://github.com/DeadZen/goldrush.git", tag: "0.1.6", override: true}
    ]
  end
end
