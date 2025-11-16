deps_with_modules = [
  phoenix: Phoenix.Router,
  ecto: Ecto.Schema,
  ecto_sql: Ecto.Migration
]

imported_deps =
  for {dep, module} <- deps_with_modules,
      Code.ensure_loaded?(module),
      do: dep

[
  import_deps: imported_deps,
  subdirectories: ["priv/*/migrations"],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  inputs: ["*.{heex,ex,exs}", "{config,lib,test}/**/*.{heex,ex,exs}", "priv/*/seeds.exs"]
]
