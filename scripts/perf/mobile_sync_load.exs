Mix.Task.run("app.start")

base_url = System.get_env("FASTCHECK_BASE_URL", "http://localhost:4000")
token = System.get_env("FASTCHECK_SCANNER_TOKEN") || raise "FASTCHECK_SCANNER_TOKEN is required"

batch_size =
  System.get_env("FASTCHECK_BATCH_SIZE", "250")
  |> String.to_integer()

batch_count =
  System.get_env("FASTCHECK_BATCH_COUNT", "4")
  |> String.to_integer()

concurrency =
  System.get_env("FASTCHECK_BATCH_CONCURRENCY", "4")
  |> String.to_integer()

ticket_codes =
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

if Enum.empty?(ticket_codes) do
  raise "No ticket codes loaded from FASTCHECK_TICKETS_FILE"
end

req =
  Req.new(
    base_url: base_url,
    headers: [
      {"accept", "application/json"},
      {"authorization", "Bearer #{token}"}
    ],
    receive_timeout: 30_000,
    connect_options: [timeout: 5_000]
  )

build_batch = fn batch_index ->
  now = DateTime.utc_now() |> DateTime.to_iso8601()

  scans =
    1..batch_size
    |> Enum.map(fn offset ->
      global_index = (batch_index - 1) * batch_size + offset

      %{
        "idempotency_key" =>
          "perf-#{batch_index}-#{offset}-#{System.unique_integer([:positive])}",
        "ticket_code" => Enum.at(ticket_codes, rem(global_index - 1, length(ticket_codes))),
        "direction" => "in",
        "scanned_at" => now,
        "entrance_name" => "Mobile Perf",
        "operator_name" => "Perf Harness"
      }
    end)

  %{"scans" => scans}
end

started_at = System.monotonic_time(:millisecond)

batch_results =
  1..batch_count
  |> Task.async_stream(
    fn batch_index ->
      payload = build_batch.(batch_index)
      request_started_at = System.monotonic_time(:microsecond)

      response = Req.post!(req, url: "/api/v1/mobile/scans", json: payload)

      duration_ms =
        (System.monotonic_time(:microsecond) - request_started_at)
        |> Kernel./(1000)

      body = response.body || %{}
      processed = get_in(body, ["data", "processed"]) || 0

      %{
        batch_index: batch_index,
        status: response.status,
        processed: processed,
        duration_ms: duration_ms
      }
    end,
    max_concurrency: concurrency,
    timeout: :infinity,
    ordered: false
  )
  |> Enum.map(fn
    {:ok, result} ->
      result

    {:exit, reason} ->
      %{batch_index: -1, status: 0, processed: 0, duration_ms: 0.0, error: inspect(reason)}
  end)

runtime_ms = System.monotonic_time(:millisecond) - started_at

total_processed = Enum.reduce(batch_results, 0, fn result, acc -> acc + result.processed end)
durations = batch_results |> Enum.map(& &1.duration_ms) |> Enum.sort()

percentile = fn percentile_value ->
  if durations == [] do
    0.0
  else
    rank = Float.ceil(percentile_value * length(durations)) |> trunc() |> max(1)
    Enum.at(durations, rank - 1, 0.0)
  end
end

summary = %{
  batch_count: batch_count,
  batch_size: batch_size,
  request_concurrency: concurrency,
  runtime_ms: runtime_ms,
  total_processed: total_processed,
  average_batch_ms:
    if(durations == [], do: 0.0, else: Float.round(Enum.sum(durations) / length(durations), 2)),
  p50_batch_ms: Float.round(percentile.(0.50), 2),
  p95_batch_ms: Float.round(percentile.(0.95), 2),
  p99_batch_ms: Float.round(percentile.(0.99), 2),
  status_counts: Enum.frequencies_by(batch_results, & &1.status)
}

IO.puts(Jason.encode!(summary, pretty: true))
