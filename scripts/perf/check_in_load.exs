Mix.Task.run("app.start")

base_url = System.get_env("FASTCHECK_BASE_URL", "http://localhost:4000")
token = System.get_env("FASTCHECK_SCANNER_TOKEN") || raise "FASTCHECK_SCANNER_TOKEN is required"

count =
  System.get_env("FASTCHECK_LOAD_COUNT", "1000")
  |> String.to_integer()

concurrency =
  System.get_env("FASTCHECK_LOAD_CONCURRENCY", "25")
  |> String.to_integer()

entrance_name = System.get_env("FASTCHECK_LOAD_ENTRANCE", "Load")
operator_name = System.get_env("FASTCHECK_LOAD_OPERATOR", "PerfHarness")

codes =
  case System.get_env("FASTCHECK_TICKETS_FILE") do
    nil ->
      raise "FASTCHECK_TICKETS_FILE must point to a newline-delimited ticket code file"

    path ->
      path
      |> File.read!()
      |> String.split(~r/\R/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

if Enum.empty?(codes) do
  raise "No ticket codes loaded from FASTCHECK_TICKETS_FILE"
end

req =
  Req.new(
    base_url: base_url,
    headers: [
      {"accept", "application/json"},
      {"authorization", "Bearer #{token}"}
    ],
    receive_timeout: 15_000,
    connect_options: [timeout: 5_000]
  )

sample_codes =
  1..count
  |> Enum.map(fn index -> Enum.at(codes, rem(index - 1, length(codes))) end)

started_at = System.monotonic_time(:millisecond)

results =
  sample_codes
  |> Task.async_stream(
    fn ticket_code ->
      payload = %{
        "ticket_code" => ticket_code,
        "entrance_name" => entrance_name,
        "operator_name" => operator_name
      }

      request_started_at = System.monotonic_time(:microsecond)

      response = Req.post!(req, url: "/api/v1/check-in", json: payload)

      duration_ms =
        (System.monotonic_time(:microsecond) - request_started_at)
        |> Kernel./(1000)

      %{status: response.status, duration_ms: duration_ms}
    end,
    max_concurrency: concurrency,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.map(fn
    {:ok, result} -> result
    {:exit, reason} -> %{status: 0, duration_ms: 0.0, error: inspect(reason)}
  end)

runtime_ms = System.monotonic_time(:millisecond) - started_at

durations = results |> Enum.map(& &1.duration_ms) |> Enum.sort()

percentile = fn percentile_value ->
  if durations == [] do
    0.0
  else
    rank = Float.ceil(percentile_value * length(durations)) |> trunc() |> max(1)
    Enum.at(durations, rank - 1, 0.0)
  end
end

status_counts = Enum.frequencies_by(results, & &1.status)
average_ms = if durations == [], do: 0.0, else: Enum.sum(durations) / length(durations)
throughput = if runtime_ms <= 0, do: 0.0, else: count / (runtime_ms / 1000)

summary = %{
  count: count,
  concurrency: concurrency,
  runtime_ms: runtime_ms,
  throughput_per_second: Float.round(throughput, 2),
  average_ms: Float.round(average_ms, 2),
  p50_ms: Float.round(percentile.(0.50), 2),
  p95_ms: Float.round(percentile.(0.95), 2),
  p99_ms: Float.round(percentile.(0.99), 2),
  status_counts: status_counts
}

IO.puts(Jason.encode!(summary, pretty: true))
