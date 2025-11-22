defmodule FastCheck.MixProject do
  use Mix.Project

  def project do
    [
      app: :fastcheck,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {FastCheck.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test, ci: :test, security: :test, quality: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.17"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:cachex, "~> 3.6"},
      {:redix, "~> 1.2"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.26"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:mishka_chelekom, "~> 0.0.8"},
      {:sourceror,
       github: "doorgan/sourceror",
       ref: "ffb1ad3c2b111371ff9c568b93ee41a145499349",
       override: true},

      # Rate limiting
      {:plug_attack, "~> 0.4.3"},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},

      # Security scanning
      # Security scanning
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},

      # Mobile Extension
      {:cors_plug, "~> 3.0"},
      {:joken, "~> 2.6"},

      # Error monitoring
      {:sentry, "~> 10.0"},
      {:hackney, "~> 1.20"},

      # Metrics export
      {:telemetry_metrics_prometheus_core, "~> 1.2"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind fastcheck", "esbuild fastcheck"],
      "assets.deploy": [
        "tailwind fastcheck --minify",
        "esbuild fastcheck --minify",
        "phx.digest"
      ],
      # Security-focused alias
      security: ["sobelow --config"],

      # Combined quality checks (code quality + security)
      quality: [
        "format --check-formatted",
        "credo --strict",
        "sobelow --exit"
      ],

      # Non-destructive CI checks - safe for automation
      ci: [
        "deps.get",
        "compile --warnings-as-errors",
        "format --check-formatted",
        "credo --strict",
        "sobelow --exit --compact",
        "test"
      ],

      # Developer precommit - may mutate mix.lock via deps.unlock
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end
end
