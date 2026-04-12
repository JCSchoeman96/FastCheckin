defmodule Mix.Tasks.DialyzerCheck do
  @moduledoc """
  Runs Dialyzer under `MIX_ENV=dev` so the PLT matches normal `mix dialyzer` builds,
  even when invoked from aliases like `mix ci` / `mix quality` (`MIX_ENV=test`).

  Uses a subprocess so the environment matches Windows/macOS/Linux without a `cmd.exe` wrapper.
  """
  use Mix.Task

  @shortdoc "Runs dialyzer with MIX_ENV=dev (for CI / quality aliases)"

  @impl Mix.Task
  def run(args) do
    mix =
      System.find_executable("mix") ||
        Mix.raise("mix executable not found in PATH")

    argv = ["dialyzer", "--quiet-with-result"] ++ List.wrap(args)

    {output, status} =
      System.cmd(mix, argv,
        env: [{"MIX_ENV", "dev"}],
        stderr_to_stdout: true
      )

    if status != 0 do
      IO.write(output)
      Mix.raise("dialyzer failed with exit #{status}")
    else
      IO.write(output)
    end
  end
end
