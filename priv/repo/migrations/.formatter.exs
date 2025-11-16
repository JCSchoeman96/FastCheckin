deps_with_modules = [ecto_sql: Ecto.Migration]

imported_deps =
  for {dep, module} <- deps_with_modules,
      Code.ensure_loaded?(module),
      do: dep

[
  import_deps: imported_deps,
  inputs: ["*.exs"]
]
