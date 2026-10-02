defmodule P1F.ObanSnapshotFixture do
  @moduledoc false

  alias FastCheck.Repo
  alias FastCheck.Scans.Jobs.PersistScanBatchJob
  alias FastCheck.Sales.Inventory.ReconciliationWorker
  alias FastCheck.Sales.Payments.PaymentRecoverySweepWorker
  alias FastCheck.Sales.Payments.PaystackWebhookWorker
  alias FastCheck.Sales.Payments.VerifyPaymentWorker
  alias FastCheck.Workers.CheckoutExpirySweeperWorker
  alias FastCheck.Workers.CheckoutExpiryWorker
  alias FastCheck.Workers.IssueTicketsWorker
  alias FastCheck.Workers.PaidOrderFulfillmentWorker
  alias FastCheck.Workers.RefundInventoryWorker
  alias FastCheck.Workers.SendWhatsAppPaymentLinkWorker
  alias FastCheck.Workers.SendWhatsAppTicketLinkWorker
  alias FastCheck.Workers.TicketDeliveryCoordinatorWorker
  alias FastCheck.Workers.WhatsAppInboundWorker

  @main_sha "a109ffae49fa9125f63fb38317169902d9034e07"
  @batch_size 1_000
  @fixture_database "fastcheck_oban_fixture"
  @fixture_ack "disposable-local-database"
  @runner "oban@fixture.invalid"

  @persisted_timestamp_fields [
    :inserted_at,
    :scheduled_at,
    :attempted_at,
    :completed_at,
    :cancelled_at,
    :discarded_at
  ]

  @states [
    :available,
    :executing,
    :retryable,
    :scheduled,
    :completed,
    :cancelled,
    :discarded_recent_1h,
    :discarded_older
  ]

  @queue_limits %{
    "scan_persistence" => 10,
    "sales_inventory" => 5,
    "payments" => 5,
    "ticketing" => 5,
    "sales_maintenance" => 3,
    "whatsapp_inbound" => 5,
    "whatsapp_outbound" => 5
  }

  @scheduled_offsets [300, 1_800, 7_200, 43_200, 86_400, 259_200, 604_800]

  @workers [
    %{
      id: :scan_persistence,
      queue: "scan_persistence",
      module: PersistScanBatchJob,
      max_attempts: 10,
      counts: %{
        "normal" => [0, 1, 1, 0, 49_997, 0, 0, 1],
        "high-pressure" => [35_990, 10, 0, 0, 0, 0, 0, 0],
        "incident" => [827_511, 10, 20_216, 7, 50_541, 1_011, 5_054, 20_216]
      }
    },
    %{
      id: :paid_order_fulfillment,
      queue: "sales_inventory",
      module: PaidOrderFulfillmentWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 0, 0, 19_997, 0, 0, 1],
        "high-pressure" => [595, 5, 0, 0, 17_600, 0, 0, 0],
        "incident" => [13_703, 5, 10_221, 7, 25_552, 511, 2_555, 10_221]
      }
    },
    %{
      id: :reconciliation,
      queue: "sales_inventory",
      module: ReconciliationWorker,
      max_attempts: 3,
      counts: %{
        "normal" => [0, 0, 0, 0, 0, 1, 0, 0],
        "high-pressure" => [0, 0, 0, 0, 0, 0, 0, 0],
        "incident" => [23, 0, 1, 0, 1, 0, 0, 1]
      }
    },
    %{
      id: :refund_inventory,
      queue: "sales_inventory",
      module: RefundInventoryWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 0, 0, 0, 0, 1, 0, 0],
        "high-pressure" => [0, 0, 0, 0, 0, 0, 0, 0],
        "incident" => [23, 0, 1, 0, 1, 0, 0, 1]
      }
    },
    %{
      id: :paystack_webhook,
      queue: "payments",
      module: PaystackWebhookWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 1, 0, 19_999, 0, 0, 1],
        "high-pressure" => [997, 3, 0, 0, 19_000, 0, 0, 0],
        "incident" => [22_946, 5, 11_231, 7, 28_079, 562, 2_808, 11_231]
      }
    },
    %{
      id: :verify_payment,
      queue: "payments",
      module: VerifyPaymentWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 0, 0, 19_998, 0, 0, 1],
        "high-pressure" => [798, 2, 0, 0, 18_200, 0, 0, 0],
        "incident" => [18_371, 0, 10_670, 0, 26_675, 533, 2_667, 10_670]
      }
    },
    %{
      id: :issue_tickets,
      queue: "ticketing",
      module: IssueTicketsWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 1, 0, 19_996, 0, 0, 1],
        "high-pressure" => [397, 3, 0, 0, 17_200, 0, 0, 0],
        "incident" => [9_151, 5, 9_884, 7, 24_710, 494, 2_471, 9_884]
      }
    },
    %{
      id: :ticket_delivery_coordinator,
      queue: "ticketing",
      module: TicketDeliveryCoordinatorWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 0, 0, 19_995, 0, 0, 1],
        "high-pressure" => [148, 2, 0, 0, 17_050, 0, 0, 0],
        "incident" => [3_426, 0, 9_659, 0, 24_148, 483, 2_415, 9_659]
      }
    },
    %{
      id: :checkout_expiry_sweeper,
      queue: "sales_maintenance",
      module: CheckoutExpirySweeperWorker,
      max_attempts: 3,
      counts: %{
        "normal" => [0, 1, 0, 0, 5_039, 0, 0, 0],
        "high-pressure" => [0, 1, 0, 0, 5_039, 0, 0, 0],
        "incident" => [23, 3, 2_831, 7, 7_077, 142, 708, 2_831]
      }
    },
    %{
      id: :payment_recovery_sweep,
      queue: "sales_maintenance",
      module: PaymentRecoverySweepWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 0, 0, 5_039, 0, 0, 0],
        "high-pressure" => [0, 1, 0, 0, 5_039, 0, 0, 0],
        "incident" => [23, 0, 2_831, 0, 7_077, 141, 708, 2_831]
      }
    },
    %{
      id: :checkout_expiry,
      queue: "sales_maintenance",
      module: CheckoutExpiryWorker,
      max_attempts: 8,
      counts: %{
        "normal" => [0, 0, 0, 0, 0, 1, 0, 0],
        "high-pressure" => [0, 1, 0, 0, 0, 0, 0, 0],
        "incident" => [23, 0, 1, 0, 3, 0, 0, 1]
      }
    },
    %{
      id: :whatsapp_inbound,
      queue: "whatsapp_inbound",
      module: WhatsAppInboundWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 0, 1, 0, 180_000, 1, 0, 1],
        "high-pressure" => [4_995, 5, 0, 0, 180_000, 0, 0, 0],
        "incident" => [114_869, 5, 103_887, 7, 259_717, 5_194, 25_972, 103_887]
      }
    },
    %{
      id: :send_whatsapp_payment_link,
      queue: "whatsapp_outbound",
      module: SendWhatsAppPaymentLinkWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 0, 0, 0, 20_000, 1, 1, 0],
        "high-pressure" => [0, 0, 0, 0, 20_000, 0, 0, 0],
        "incident" => [23, 0, 11_231, 0, 28_079, 562, 2_808, 11_231]
      }
    },
    %{
      id: :send_whatsapp_ticket_link,
      queue: "whatsapp_outbound",
      module: SendWhatsAppTicketLinkWorker,
      max_attempts: 5,
      counts: %{
        "normal" => [0, 1, 0, 0, 19_994, 0, 1, 1],
        "high-pressure" => [45, 5, 0, 0, 17_000, 0, 0, 0],
        "incident" => [1_057, 5, 9_575, 7, 23_937, 479, 2_394, 9_575]
      }
    },
    %{
      id: :unexpected,
      queue: "__unexpected__",
      raw_queue: "p1f_fixture_unexpected",
      worker_name: "FastCheck.PerfFixtures.UnexpectedSource",
      max_attempts: 3,
      counts: %{
        "normal" => [0, 0, 0, 0, 0, 0, 0, 0],
        "high-pressure" => [0, 0, 0, 0, 0, 0, 0, 0],
        "incident" => [23, 0, 0, 7, 1, 0, 0, 0]
      }
    }
  ]

  @scenarios %{
    "normal" => %{
      name: "NORMAL_LAUNCH_MODEL",
      total: 380_082,
      states: [0, 9, 4, 0, 380_054, 5, 2, 8],
      payloads: [304_066, 72_215, 3_801],
      sha256: "ceebadd04dece75cf46c0d8ba31a80af745d8f2d28f9b127d9af84d4c6c0b79a"
    },
    "high-pressure" => %{
      name: "HIGH_PRESSURE_LAUNCH_MODEL",
      total: 360_131,
      states: [43_965, 38, 0, 0, 316_128, 0, 0, 0],
      payloads: [252_092, 90_033, 18_006],
      sha256: "bd14fafdb5083b52ed716cbd25d2e329468239210e9758d16561eaa8b73224ef"
    },
    "incident" => %{
      name: "INCIDENT_STRESS_MODEL",
      total: 1_982_037,
      states: [1_011_195, 38, 202_239, 56, 505_598, 10_112, 50_560, 202_239],
      payloads: [1_189_222, 594_611, 198_204],
      sha256: "2740acc0ad432496c12cf422c8c7a6328773f7d96aca4823505502509e98bd92"
    }
  }

  @timestamp_buckets %{
    "normal" => %{
      available: [],
      retryable: [{1, 600, 600}, {1, 1_800, 1_800}, {1, 3_600, 3_600}, {1, 7_200, 7_200}],
      completed: [{380_054, 1, 604_800}],
      cancelled: [{5, 1, 604_800}],
      discarded_recent_1h: [{1, 300, 300}, {1, 3_300, 3_300}],
      discarded_older: [{8, 172_800, 518_400}]
    },
    "high-pressure" => %{
      available: [{26_379, 1, 300}, {13_190, 301, 1_800}, {4_396, 1_801, 3_600}],
      retryable: [],
      completed: [{316_128, 1, 604_800}],
      cancelled: [],
      discarded_recent_1h: [],
      discarded_older: []
    },
    "incident" => %{
      available: [
        {303_359, 1, 300},
        {303_358, 301, 604_800},
        {404_478, 691_200, 2_592_000}
      ],
      retryable: [
        {50_560, 1, 3_600},
        {50_560, 3_601, 604_800},
        {101_119, 691_200, 2_592_000}
      ],
      completed: [{353_919, 1, 604_800}, {151_679, 691_200, 2_592_000}],
      cancelled: [{5_056, 1, 604_800}, {5_056, 691_200, 2_592_000}],
      discarded_recent_1h: [{50_560, 300, 3_300}],
      discarded_older: [{202_239, 172_800, 518_400}]
    }
  }

  def main(args) do
    with {:ok, options} <- parse_args(args),
         {:ok, scenario_key} <- fetch_scenario(options),
         {:ok, fixture_time} <- parse_time(options),
         scenario = Map.fetch!(@scenarios, scenario_key),
         :ok <- validate_spec(scenario_key, scenario, fixture_time) do
      generated_sha = manifest_sha256(scenario, row_vectors(scenario_key))
      print_summary(scenario, fixture_time, generated_sha)

      cond do
        options.validate_only -> :ok
        options.load -> load_fixture(scenario_key, scenario, fixture_time)
        true -> {:error, "choose either --validate-only or --load"}
      end
    end
    |> case do
      :ok ->
        :ok

      {:error, message} ->
        IO.puts(:stderr, "oban snapshot fixture: #{message}")
        System.halt(1)
    end
  rescue
    error ->
      IO.puts(:stderr, "oban snapshot fixture: #{Exception.message(error)}")
      System.halt(1)
  end

  defp parse_args(args) do
    args = if List.first(args) == "--", do: tl(args), else: args

    {options, positional, invalid} =
      OptionParser.parse(args,
        strict: [now: :string, validate_only: :boolean, load: :boolean],
        aliases: [],
        switches_before_args: false
      )

    cond do
      invalid != [] ->
        {:error, "unknown or invalid options: #{inspect(invalid)}"}

      length(positional) != 1 ->
        {:error,
         "usage: oban_snapshot_fixture.exs <normal|high-pressure|incident> --now <UTC RFC3339> (--validate-only|--load)"}

      Keyword.get(options, :validate_only, false) == Keyword.get(options, :load, false) ->
        {:error, "choose exactly one of --validate-only or --load"}

      true ->
        {:ok,
         %{
           scenario: hd(positional),
           now: Keyword.get(options, :now),
           validate_only: Keyword.get(options, :validate_only, false),
           load: Keyword.get(options, :load, false)
         }}
    end
  end

  defp fetch_scenario(%{scenario: scenario}) do
    if Map.has_key?(@scenarios, scenario),
      do: {:ok, scenario},
      else: {:error, "scenario must be normal, high-pressure, or incident"}
  end

  defp parse_time(%{now: nil}), do: {:error, "--now <UTC RFC3339> is required"}

  defp parse_time(%{now: value}) do
    case DateTime.from_iso8601(value) do
      {:ok,
       %DateTime{
         utc_offset: 0,
         std_offset: 0,
         microsecond: {value, _precision}
       } = datetime, 0} ->
        {:ok, %DateTime{datetime | microsecond: {value, 6}}}

      {:ok, _datetime, _offset} -> {:error, "--now must use UTC (Z or +00:00)"}
      {:error, _reason} -> {:error, "--now must be a valid UTC RFC3339 timestamp"}
    end
  end

  defp validate_spec(scenario_key, scenario, fixture_time) do
    vectors = row_vectors(scenario_key)
    actual_states = state_totals(scenario_key)
    actual_total = Enum.sum(actual_states)
    actual_payload_total = Enum.sum(scenario.payloads)

    cond do
      actual_states != scenario.states ->
        {:error, "#{scenario.name} state totals differ from approved v3"}

      actual_total != scenario.total ->
        {:error, "#{scenario.name} total differs from approved v3"}

      actual_payload_total != scenario.total ->
        {:error, "#{scenario.name} payload class counts do not sum to the approved total"}

      true ->
        with :ok <- validate_worker_authority(),
             :ok <- validate_executing_limits(scenario_key),
             :ok <- validate_timestamp_buckets(scenario_key),
             :ok <- validate_payload_widths(scenario_key, fixture_time),
             :ok <- validate_generated_rows(scenario_key, fixture_time, scenario),
             hash = manifest_sha256(scenario, vectors),
             true <- hash == scenario.sha256 do
          :ok
        else
          false -> {:error, "#{scenario.name} canonical manifest hash differs from approved v3"}
          {:error, _} = error -> error
        end
    end
  end

  defp validate_worker_authority do
    Enum.reduce_while(@workers, :ok, fn worker, :ok ->
      case worker_authority(worker) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp worker_authority(%{module: module, queue: expected_queue} = worker) do
    options = module.__opts__()
    canonical_name = Oban.Worker.to_string(module)
    actual_queue = options |> Keyword.fetch!(:queue) |> to_string()
    max_attempts = Keyword.fetch!(options, :max_attempts)

    cond do
      canonical_name != worker_name(worker) ->
        {:error, "worker name differs from the canonical Oban name for #{inspect(module)}"}

      actual_queue != expected_queue ->
        {:error, "queue differs from pinned worker configuration for #{canonical_name}"}

      max_attempts != worker.max_attempts ->
        {:error, "max_attempts differs from pinned worker configuration for #{canonical_name}"}

      true ->
        :ok
    end
  end

  defp worker_authority(
         %{id: :unexpected, queue: "__unexpected__", raw_queue: raw_queue} = worker
       ) do
    if raw_queue == "p1f_fixture_unexpected" and
         worker_name(worker) == "FastCheck.PerfFixtures.UnexpectedSource" and
         worker.max_attempts == 3 do
      :ok
    else
      {:error, "fixture unexpected-source sentinel differs from approved v3"}
    end
  end

  defp validate_executing_limits(scenario_key) do
    executing_by_queue =
      Enum.reduce(@workers, %{}, fn worker, totals ->
        [_, executing | _] = Map.fetch!(worker.counts, scenario_key)
        Map.update(totals, worker.queue, executing, &(&1 + executing))
      end)

    over_limit =
      Enum.find(executing_by_queue, fn {queue, count} ->
        count > Map.get(@queue_limits, queue, 0)
      end)

    total = Enum.sum(Map.values(executing_by_queue))

    cond do
      over_limit ->
        {:error, "executing rows exceed configured concurrency for #{elem(over_limit, 0)}"}

      total > 38 ->
        {:error, "executing rows exceed the single-node limit of 38"}

      true ->
        :ok
    end
  end

  defp validate_timestamp_buckets(scenario_key) do
    buckets = Map.fetch!(@timestamp_buckets, scenario_key)

    Enum.reduce_while(buckets, :ok, fn {state, entries}, :ok ->
      expected =
        @workers
        |> Enum.map(fn worker ->
          worker.counts |> Map.fetch!(scenario_key) |> Enum.at(state_index(state))
        end)
        |> Enum.sum()

      valid_entries? =
        Enum.all?(entries, fn {count, min_age, max_age} ->
          count > 0 and min_age > 0 and max_age >= min_age
        end)

      actual = Enum.reduce(entries, 0, fn {count, _min_age, _max_age}, sum -> sum + count end)

      if valid_entries? and actual == expected do
        {:cont, :ok}
      else
        {:halt, {:error, "#{scenario_key} #{state} timestamp buckets do not match the row count"}}
      end
    end)
  end

  defp validate_payload_widths(scenario_key, fixture_time) do
    args = worker_args(:scan_persistence, 9_000_000_000, fixture_time)

    widths =
      [:small, :typical, :wide]
      |> Enum.map(fn profile ->
        meta = fixture_meta(profile, 0, scenario_key)
        byte_size(Jason.encode!(args)) + byte_size(Jason.encode!(meta))
      end)

    case widths do
      [small, typical, wide]
      when small <= 256 and typical in 257..2_048 and wide in 4_096..8_192 ->
        :ok

      _ ->
        {:error,
         "synthetic args/meta width profiles fall outside their approved logical ranges: #{inspect(widths)}"}
    end
  end

  defp validate_generated_rows(scenario_key, fixture_time, scenario) do
    initial = %{
      row_count: 0,
      worker_states: zero_worker_state_counts(scenario_key),
      payloads: %{small: 0, typical: 0, wide: 0},
      timestamp_buckets: %{}
    }

    result =
      fixture_base_rows(scenario_key)
      |> Enum.reduce_while({:ok, initial}, fn {row, global_index}, {:ok, totals} ->
        job = build_job(row, scenario_key, fixture_time, global_index, scenario, false)
        worker = row.worker
        state = row.state
        class = payload_class(global_index, scenario)
        precision_valid? = valid_persisted_timestamp_precision?(job)

        cond do
          job.queue != raw_queue(worker) or job.worker != worker_name(worker) ->
            {:halt,
             {:error, "generated queue or worker differs from canonical fixture authority"}}

          not precision_valid? ->
            {:halt,
             {:error,
              "generated #{state} row timestamps must have microsecond precision 6 when present"}}

          not valid_job?(job, fixture_time, actual_max_attempts(worker)) ->
            {:halt,
             {:error,
              "generated #{state} row violates Oban lifecycle invariants for #{worker_name(worker)}"}}

          not valid_state_offset?(row, job, fixture_time) ->
            {:halt,
             {:error,
              "generated #{state} timestamp offset differs from the approved deterministic distribution"}}

          true ->
            case add_timestamp_bucket(
                   totals.timestamp_buckets,
                   row,
                   job,
                   scenario_key,
                   fixture_time
                 ) do
              {:ok, buckets} ->
                next = %{
                  totals
                  | row_count: totals.row_count + 1,
                    worker_states:
                      Map.update(totals.worker_states, {worker.id, state}, 1, &(&1 + 1)),
                    payloads: Map.update!(totals.payloads, class, &(&1 + 1)),
                    timestamp_buckets: buckets
                }

                {:cont, {:ok, next}}

              {:error, _} = error ->
                {:halt, error}
            end
        end
      end)

    with {:ok, totals} <- result,
         :ok <- validate_generated_totals(scenario_key, scenario, totals),
         :ok <- validate_generated_bucket_totals(scenario_key, totals.timestamp_buckets) do
      :ok
    end
  end

  defp valid_persisted_timestamp_precision?(job) do
    Enum.all?(@persisted_timestamp_fields, fn field ->
      case Map.fetch!(job, field) do
        nil -> true
        %DateTime{microsecond: {_value, 6}} -> true
        _ -> false
      end
    end)
  end

  defp valid_state_offset?(%{state: :executing, state_ordinal: ordinal}, job, fixture_time) do
    DateTime.diff(fixture_time, job.attempted_at, :second) == rem(ordinal, 30) + 1
  end

  defp valid_state_offset?(%{state: :scheduled, state_ordinal: ordinal}, job, fixture_time) do
    expected = Enum.at(@scheduled_offsets, rem(ordinal, length(@scheduled_offsets)))
    DateTime.diff(job.scheduled_at, fixture_time, :second) == expected
  end

  defp valid_state_offset?(_row, _job, _fixture_time), do: true

  defp add_timestamp_bucket(buckets, %{state: state}, job, scenario_key, fixture_time) do
    case timestamp_age(state, job, fixture_time) do
      nil ->
        {:ok, buckets}

      age ->
        definitions = Map.fetch!(Map.fetch!(@timestamp_buckets, scenario_key), state)

        case Enum.find_index(definitions, fn {_count, min_age, max_age} ->
               age in min_age..max_age
             end) do
          nil ->
            {:error, "generated #{state} timestamp falls outside its approved bucket ranges"}

          bucket_index ->
            {:ok, Map.update(buckets, {state, bucket_index}, 1, &(&1 + 1))}
        end
    end
  end

  defp timestamp_age(:available, job, fixture_time),
    do: DateTime.diff(fixture_time, job.inserted_at, :second)

  defp timestamp_age(:retryable, job, fixture_time),
    do: DateTime.diff(fixture_time, job.attempted_at, :second)

  defp timestamp_age(:completed, job, fixture_time),
    do: DateTime.diff(fixture_time, job.completed_at, :second)

  defp timestamp_age(:cancelled, job, fixture_time),
    do: DateTime.diff(fixture_time, job.cancelled_at, :second)

  defp timestamp_age(:discarded_recent_1h, job, fixture_time),
    do: DateTime.diff(fixture_time, job.discarded_at, :second)

  defp timestamp_age(:discarded_older, job, fixture_time),
    do: DateTime.diff(fixture_time, job.discarded_at, :second)

  defp timestamp_age(_state, _job, _fixture_time), do: nil

  defp validate_generated_totals(scenario_key, scenario, totals) do
    expected_payloads =
      scenario.payloads
      |> Enum.zip([:small, :typical, :wide])
      |> Map.new(fn {count, class} -> {class, count} end)

    cond do
      totals.row_count != scenario.total ->
        {:error, "generated row count differs from approved #{scenario.name} total"}

      totals.worker_states != expected_worker_state_counts(scenario_key) ->
        {:error,
         "generated per-worker state counts differ from approved #{scenario.name} vectors"}

      totals.payloads != expected_payloads ->
        {:error, "generated payload classes differ from approved #{scenario.name} totals"}

      true ->
        :ok
    end
  end

  defp expected_worker_state_counts(scenario_key) do
    for worker <- @workers, state <- @states, into: %{} do
      count = Enum.at(Map.fetch!(worker.counts, scenario_key), state_index(state))
      {{worker.id, state}, count}
    end
  end

  defp zero_worker_state_counts(scenario_key) do
    scenario_key
    |> expected_worker_state_counts()
    |> Map.new(fn {worker_state, _count} -> {worker_state, 0} end)
  end

  defp validate_generated_bucket_totals(scenario_key, actual) do
    expected =
      @timestamp_buckets
      |> Map.fetch!(scenario_key)
      |> Enum.reduce(%{}, fn {state, definitions}, totals ->
        definitions
        |> Enum.with_index()
        |> Enum.reduce(totals, fn {{count, _min_age, _max_age}, index}, acc ->
          Map.put(acc, {state, index}, count)
        end)
      end)

    if actual == expected do
      :ok
    else
      {:error,
       "generated timestamp bucket counts differ from approved #{scenario_key} distributions"}
    end
  end

  defp valid_job?(job, fixture_time, max_attempts) do
    no_terminal =
      is_nil(job.completed_at) and is_nil(job.cancelled_at) and is_nil(job.discarded_at)

    case job.state do
      "available" ->
        job.attempt == 0 and is_nil(job.attempted_by) and is_nil(job.attempted_at) and
          DateTime.compare(job.inserted_at, job.scheduled_at) != :gt and
          DateTime.compare(job.scheduled_at, fixture_time) != :gt and no_terminal and
          job.errors == []

      "executing" ->
        job.attempt >= 1 and job.attempt <= max_attempts and is_list(job.attempted_by) and
          job.attempted_by != [] and not is_nil(job.attempted_at) and
          DateTime.compare(job.inserted_at, job.scheduled_at) != :gt and
          DateTime.compare(job.scheduled_at, job.attempted_at) != :gt and
          DateTime.diff(fixture_time, job.attempted_at, :second) in 1..30 and
          no_terminal and job.errors == []

      "retryable" ->
        job.attempt >= 1 and job.attempt < max_attempts and is_list(job.attempted_by) and
          job.attempted_by != [] and not is_nil(job.attempted_at) and job.errors != [] and
          DateTime.compare(job.inserted_at, job.attempted_at) != :gt and
          DateTime.compare(job.attempted_at, fixture_time) == :lt and
          DateTime.compare(job.scheduled_at, DateTime.add(fixture_time, 60, :second)) == :eq and
          no_terminal and job.errors == [synthetic_error(1, job.attempted_at)]

      "scheduled" ->
        scheduled_offset = DateTime.diff(job.scheduled_at, fixture_time, :second)

        job.attempt == 0 and is_nil(job.attempted_by) and is_nil(job.attempted_at) and
          DateTime.compare(job.inserted_at, fixture_time) != :gt and
          scheduled_offset in @scheduled_offsets and no_terminal and job.errors == []

      "completed" ->
        job.attempt == 1 and is_list(job.attempted_by) and job.attempted_by != [] and
          not is_nil(job.completed_at) and ordered_timestamps?(job) and
          DateTime.compare(job.completed_at, fixture_time) != :gt and
          is_nil(job.cancelled_at) and is_nil(job.discarded_at) and job.errors == []

      "cancelled" ->
        job.attempt == 0 and is_nil(job.attempted_by) and is_nil(job.attempted_at) and
          DateTime.compare(job.inserted_at, job.scheduled_at) != :gt and
          not is_nil(job.cancelled_at) and DateTime.compare(job.cancelled_at, fixture_time) != :gt and
          is_nil(job.completed_at) and is_nil(job.discarded_at) and job.errors == []

      "discarded" ->
        job.attempt == max_attempts and is_list(job.attempted_by) and job.attempted_by != [] and
          not is_nil(job.attempted_at) and not is_nil(job.discarded_at) and
          DateTime.compare(job.inserted_at, job.scheduled_at) != :gt and
          DateTime.compare(job.scheduled_at, job.attempted_at) != :gt and
          DateTime.compare(job.attempted_at, job.discarded_at) == :lt and
          DateTime.compare(job.discarded_at, fixture_time) != :gt and
          is_nil(job.completed_at) and is_nil(job.cancelled_at) and
          valid_discarded_errors?(job.errors, max_attempts, job.inserted_at, job.attempted_at)
    end
  end

  defp ordered_timestamps?(job) do
    [job.inserted_at, job.scheduled_at, job.attempted_at, job.completed_at]
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [first, second] -> DateTime.compare(first, second) != :gt end)
  end

  defp valid_discarded_errors?(errors, max_attempts, inserted_at, attempted_at) do
    length(errors) == max_attempts and
      Enum.all?(Enum.with_index(errors, 1), fn {error, attempt} ->
        expected_at = DateTime.add(inserted_at, 60 * (attempt - 1), :second)

        error["attempt"] == attempt and error["at"] == DateTime.to_iso8601(expected_at) and
          error["error"] == "P1F synthetic fixture failure #{attempt}"
      end) and
      DateTime.compare(DateTime.add(inserted_at, 60 * (max_attempts - 1), :second), attempted_at) ==
        :eq
  end

  defp row_vectors(scenario_key) do
    Enum.map(@workers, fn worker ->
      [worker.queue, worker_name(worker) | Map.fetch!(worker.counts, scenario_key)]
    end)
  end

  defp state_totals(scenario_key) do
    Enum.map(0..(length(@states) - 1), fn index ->
      @workers
      |> Enum.map(&(Map.fetch!(&1.counts, scenario_key) |> Enum.at(index)))
      |> Enum.sum()
    end)
  end

  defp manifest_sha256(scenario, vectors) do
    payload = [@main_sha, scenario.name, vectors, scenario.payloads]
    bytes = Jason.encode!(payload, escape: :json)
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end

  defp print_summary(scenario, fixture_time, generated_sha) do
    [
      available,
      executing,
      retryable,
      scheduled,
      completed,
      cancelled,
      discarded_recent,
      discarded_older
    ] =
      scenario.states

    [small, typical, wide] = scenario.payloads

    IO.puts("Scenario=#{scenario.name}")
    IO.puts("NOW=#{DateTime.to_iso8601(fixture_time)}")
    IO.puts("TOTAL_ROWS=#{scenario.total}")
    IO.puts("AVAILABLE=#{available}")
    IO.puts("EXECUTING=#{executing}")
    IO.puts("RETRYABLE=#{retryable}")
    IO.puts("SCHEDULED=#{scheduled}")
    IO.puts("COMPLETED=#{completed}")
    IO.puts("CANCELLED=#{cancelled}")
    IO.puts("DISCARDED_RECENT_1H=#{discarded_recent}")
    IO.puts("DISCARDED_OLDER=#{discarded_older}")
    IO.puts("PAYLOAD_INLINE_SMALL=#{small}")
    IO.puts("PAYLOAD_INLINE_TYPICAL=#{typical}")
    IO.puts("PAYLOAD_TOASTED_WIDE=#{wide}")
    IO.puts("MANIFEST_SHA256=#{generated_sha}")
  end

  defp load_fixture(scenario_key, scenario, fixture_time) do
    with :ok <- ensure_minimal_runtime(),
         {:ok, url} <- fixture_database_url(),
         :ok <- ensure_database_runtime(),
         {:ok, repo_pid} <- Repo.start_link(url: url, pool_size: 1, log: false) do
      try do
        with :ok <- check_database!(scenario_key) do
          insert_rows(scenario_key, scenario, fixture_time)
        end
      after
        Supervisor.stop(repo_pid)
      end
    end
  end

  defp ensure_minimal_runtime do
    if fastcheck_started?() or not is_nil(Process.whereis(Repo)) do
      {:error,
       "load mode requires mix run --no-start and a VM with FastCheck.Repo not already started"}
    else
      :ok
    end
  end

  defp ensure_database_runtime do
    with :ok <- ensure_runtime_application(:ecto_sql),
         :ok <- ensure_runtime_application(:postgrex),
         :ok <- ensure_fastcheck_stopped() do
      :ok
    end
  end

  defp ensure_runtime_application(application) do
    case Application.ensure_all_started(application) do
      {:ok, _started} ->
        :ok

      {:error, {failed_application, reason}} ->
        {:error,
         "failed to start database runtime application #{application} (#{failed_application}): #{inspect(reason)}"}
    end
  end

  defp ensure_fastcheck_stopped do
    if fastcheck_started?() do
      {:error,
       "database dependency startup unexpectedly started :fastcheck; refusing to start FastCheck.Repo"}
    else
      :ok
    end
  end

  defp fastcheck_started? do
    Enum.any?(Application.started_applications(), fn {application, _description, _version} ->
      application == :fastcheck
    end)
  end

  defp fixture_database_url do
    url = System.get_env("OBAN_FIXTURE_DATABASE_URL")
    acknowledgement = System.get_env("P1F_OBAN_FIXTURE_ACK")

    cond do
      is_nil(url) or String.trim(url) == "" ->
        {:error, "OBAN_FIXTURE_DATABASE_URL is required for --load"}

      acknowledgement != @fixture_ack ->
        {:error, "P1F_OBAN_FIXTURE_ACK must equal #{@fixture_ack}"}

      true ->
        validate_fixture_url(url)
    end
  end

  defp validate_fixture_url(url) do
    uri = URI.parse(url)
    database = uri.path |> to_string() |> String.trim_leading("/")

    cond do
      uri.scheme not in ["postgres", "postgresql"] ->
        {:error, "fixture URL must use postgres or postgresql"}

      not is_nil(uri.query) or not is_nil(uri.fragment) ->
        {:error, "fixture URL must not contain query parameters or a fragment"}

      uri.host not in ["localhost", "127.0.0.1", "::1"] ->
        {:error, "fixture database host must be localhost, 127.0.0.1, or ::1"}

      database != @fixture_database ->
        {:error, "fixture database name must be #{@fixture_database}"}

      true ->
        {:ok, url}
    end
  end

  defp check_database!(scenario_key) do
    version = Repo.query!("SHOW server_version").rows |> hd() |> hd()
    version_major = version |> String.split(".") |> hd()

    database = Repo.query!("SELECT current_database()").rows |> hd() |> hd()
    table = Repo.query!("SELECT to_regclass('public.oban_jobs')").rows |> hd() |> hd()

    cond do
      version_major != "18" ->
        {:error, "PostgreSQL 18 is required, found #{version}"}

      database != @fixture_database ->
        {:error, "connected database is not #{@fixture_database}"}

      is_nil(table) ->
        {:error, "public.oban_jobs does not exist; apply repository migrations first"}

      true ->
        count = Repo.query!("SELECT COUNT(*)::bigint FROM public.oban_jobs").rows |> hd() |> hd()

        if count == 0 do
          IO.puts("DB_GATES=PASS scenario=#{scenario_key} server_version=#{version} row_count=0")
          :ok
        else
          {:error, "public.oban_jobs must be empty before load, found #{count} rows"}
        end
    end
  end

  defp insert_rows(scenario_key, scenario, fixture_time) do
    stream = fixture_rows(scenario_key, scenario, fixture_time)

    stream
    |> Stream.chunk_every(@batch_size)
    |> Enum.reduce_while(0, fn batch, inserted ->
      case Repo.insert_all(Oban.Job, batch) do
        {count, nil} when count == length(batch) ->
          next_total = inserted + count
          if rem(next_total, 100_000) == 0, do: IO.puts("INSERTED_ROWS=#{next_total}")
          {:cont, next_total}

        result ->
          {:halt,
           {:error,
            "batch insert returned unexpected result #{inspect(result)} after #{inserted} rows"}}
      end
    end)
    |> case do
      count when is_integer(count) and count == scenario.total ->
        IO.puts("INSERTED_ROWS=#{count}")
        :ok

      count when is_integer(count) ->
        {:error, "inserted #{count} rows, expected #{scenario.total}"}

      {:error, _} = error ->
        error
    end
  end

  defp fixture_base_rows(scenario_key) do
    state_offsets = state_offsets(scenario_key)

    Stream.flat_map(@workers, fn worker ->
      Stream.flat_map(@states, fn state ->
        count = worker.counts |> Map.fetch!(scenario_key) |> Enum.at(state_index(state))
        start = state_offsets |> Map.fetch!(state) |> Map.fetch!(worker.id)

        if count == 0 do
          []
        else
          Stream.map(0..(count - 1), fn local_index ->
            build_base_row(worker, state, start + local_index, local_index)
          end)
        end
      end)
    end)
    |> Stream.with_index()
  end

  defp fixture_rows(scenario_key, scenario, fixture_time) do
    fixture_base_rows(scenario_key)
    |> Stream.map(fn {row, global_index} ->
      build_job(row, scenario_key, fixture_time, global_index, scenario)
    end)
  end

  defp build_base_row(worker, state, state_ordinal, local_index) do
    %{
      worker: worker,
      state: state,
      state_ordinal: state_ordinal,
      local_index: local_index
    }
  end

  defp build_job(
         row,
         scenario_key,
         fixture_time,
         global_index,
         scenario,
         include_padding? \\ true
       ) do
    worker = row.worker
    max_attempts = actual_max_attempts(worker)
    state = row.state
    timestamp = state_timestamps(state, row.state_ordinal, scenario_key, fixture_time, worker)
    payload_class = payload_class(global_index, scenario)
    synthetic_id = 9_000_000_000 + global_index
    args = worker_args(worker.id, synthetic_id, fixture_time)
    meta = fixture_meta(payload_class, global_index, scenario_key, include_padding?)
    {attempt, attempted_by, errors} = attempt_fields(state, max_attempts, timestamp)

    %{
      state: oban_state(state),
      queue: raw_queue(worker),
      worker: worker_name(worker),
      args: args,
      meta: meta,
      tags: ["p1f-fixture"],
      errors: errors,
      attempt: attempt,
      max_attempts: max_attempts,
      priority: 0,
      attempted_by: attempted_by,
      inserted_at: Map.fetch!(timestamp, :inserted_at),
      scheduled_at: Map.fetch!(timestamp, :scheduled_at),
      attempted_at: Map.get(timestamp, :attempted_at),
      completed_at: Map.get(timestamp, :completed_at),
      cancelled_at: Map.get(timestamp, :cancelled_at),
      discarded_at: Map.get(timestamp, :discarded_at)
    }
  end

  defp state_timestamps(:available, ordinal, scenario, now, _worker) do
    age = bucket_age(:available, ordinal, scenario)
    inserted = DateTime.add(now, -age, :second)
    %{inserted_at: inserted, scheduled_at: inserted}
  end

  defp state_timestamps(:executing, ordinal, _scenario, now, _worker) do
    attempted = DateTime.add(now, -(rem(ordinal, 30) + 1), :second)
    scheduled = DateTime.add(attempted, -60, :second)
    %{inserted_at: scheduled, scheduled_at: scheduled, attempted_at: attempted}
  end

  defp state_timestamps(:retryable, ordinal, scenario, now, _worker) do
    age = bucket_age(:retryable, ordinal, scenario)
    attempted = DateTime.add(now, -age, :second)
    inserted = DateTime.add(attempted, -300, :second)

    %{
      inserted_at: inserted,
      scheduled_at: DateTime.add(now, 60, :second),
      attempted_at: attempted
    }
  end

  defp state_timestamps(:scheduled, ordinal, _scenario, now, _worker) do
    scheduled =
      DateTime.add(
        now,
        Enum.at(@scheduled_offsets, rem(ordinal, length(@scheduled_offsets))),
        :second
      )

    %{inserted_at: DateTime.add(now, -60, :second), scheduled_at: scheduled}
  end

  defp state_timestamps(:completed, ordinal, scenario, now, _worker) do
    age = bucket_age(:completed, ordinal, scenario)
    completed = DateTime.add(now, -age, :second)
    attempted = DateTime.add(completed, -60, :second)
    scheduled = DateTime.add(attempted, -60, :second)
    inserted = DateTime.add(scheduled, -60, :second)

    %{
      inserted_at: inserted,
      scheduled_at: scheduled,
      attempted_at: attempted,
      completed_at: completed
    }
  end

  defp state_timestamps(:cancelled, ordinal, scenario, now, _worker) do
    age = bucket_age(:cancelled, ordinal, scenario)
    cancelled = DateTime.add(now, -age, :second)
    %{inserted_at: cancelled, scheduled_at: cancelled, cancelled_at: cancelled}
  end

  defp state_timestamps(:discarded_recent_1h, ordinal, scenario, now, worker) do
    discarded_timestamps(:discarded_recent_1h, ordinal, scenario, now, worker)
  end

  defp state_timestamps(:discarded_older, ordinal, scenario, now, worker) do
    discarded_timestamps(:discarded_older, ordinal, scenario, now, worker)
  end

  defp discarded_timestamps(state, ordinal, scenario, now, worker) do
    age = bucket_age(state, ordinal, scenario)
    discarded = DateTime.add(now, -age, :second)
    attempted = DateTime.add(discarded, -60, :second)
    inserted = DateTime.add(attempted, -60 * (actual_max_attempts(worker) - 1), :second)

    %{
      inserted_at: inserted,
      scheduled_at: DateTime.add(attempted, -1, :second),
      attempted_at: attempted,
      discarded_at: discarded
    }
  end

  defp bucket_age(state, ordinal, scenario_key) do
    buckets = Map.fetch!(Map.fetch!(@timestamp_buckets, scenario_key), state)
    total = Enum.reduce(buckets, 0, fn {count, _, _}, sum -> sum + count end)
    rank = permutation_rank(ordinal, total, seed(scenario_key, Atom.to_string(state)))
    select_bucket_age(rank, buckets, scenario_key, Atom.to_string(state))
  end

  defp select_bucket_age(rank, [{count, min_age, max_age} | rest], scenario, key) do
    if rank < count do
      spread_offset(rank, count, max_age - min_age + 1, seed(scenario, key <> ":age"))
      |> then(&(&1 + min_age))
    else
      select_bucket_age(rank - count, rest, scenario, key)
    end
  end

  defp spread_offset(position, count, width, seed_value) do
    {offset, stride} = permutation_params(count, seed_value)
    ranked = rem(position * stride + offset, count)

    if count <= width do
      if count == 1, do: 0, else: div(ranked * (width - 1), count - 1)
    else
      rem(ranked, width)
    end
  end

  # A seed-derived affine permutation ranks ordinals without sorting or retaining rows.
  # Coprime strides make the ranking bijective, so bucket quotas remain exact.
  defp permutation_rank(_ordinal, 1, _seed), do: 0

  defp permutation_rank(ordinal, total, seed_value) do
    {offset, stride} = permutation_params(total, seed_value)
    rem(ordinal * stride + offset, total)
  end

  defp permutation_params(1, _seed), do: {0, 1}

  defp permutation_params(modulus, seed_value) do
    <<offset_bytes::unsigned-64, stride_bytes::unsigned-64, _::binary>> =
      :crypto.hash(:sha256, seed_value)

    offset = rem(offset_bytes, modulus)
    initial = rem(stride_bytes, modulus)
    stride = coprime_stride(max(initial, 1), modulus)
    {offset, stride}
  end

  defp coprime_stride(candidate, modulus) do
    if gcd(candidate, modulus) == 1 do
      candidate
    else
      coprime_stride(rem(candidate, modulus) + 1, modulus)
    end
  end

  defp gcd(left, 0), do: left
  defp gcd(left, right), do: gcd(right, rem(left, right))

  defp payload_class(global_index, scenario) do
    [small, typical, _wide] = scenario.payloads
    total = scenario.total
    rank = permutation_rank(global_index, total, seed(scenario.name, "payload-class"))

    cond do
      rank < small -> :small
      rank < small + typical -> :typical
      true -> :wide
    end
  end

  defp fixture_meta(payload_class, global_index, scenario_key, include_padding? \\ true) do
    base = %{
      "fixture" => "p1f-oban-snapshot",
      "scenario" => scenario_key,
      "payload_class" => Atom.to_string(payload_class)
    }

    case payload_class do
      :small ->
        %{"f" => "p1f"}

      :typical ->
        length =
          512 +
            rem(permutation_rank(global_index, 1_025, seed(scenario_key, "typical-width")), 1_025)

        meta = Map.put(base, "payload_class", "typical")

        if include_padding?,
          do: Map.put(meta, "padding", synthetic_padding(global_index, length, scenario_key)),
          else: meta

      :wide ->
        length =
          4_096 +
            rem(permutation_rank(global_index, 3_200, seed(scenario_key, "wide-width")), 3_200)

        meta = Map.put(base, "payload_class", "wide")

        if include_padding?,
          do: Map.put(meta, "padding", synthetic_padding(global_index, length, scenario_key)),
          else: meta
    end
  end

  defp synthetic_padding(global_index, length, scenario_key) do
    seed_value = seed(scenario_key, "padding:#{global_index}")
    chunks = div(length + 43, 44)

    0..(chunks - 1)
    |> Enum.map(fn counter ->
      :crypto.hash(:sha256, [seed_value, <<counter::unsigned-32>>])
      |> Base.encode64()
    end)
    |> IO.iodata_to_binary()
    |> binary_part(0, length)
  end

  defp worker_args(:scan_persistence, id, now) do
    %{
      "results" => [
        %{
          "idempotency_key" => "p1f-#{id}",
          "ticket_code" => "P1F-PERF-#{id}",
          "direction" => "in",
          "scanned_at" => DateTime.to_iso8601(now),
          "entrance_name" => "E",
          "operator_name" => "P1F"
        }
      ]
    }
  end

  defp worker_args(:paid_order_fulfillment, id, _now), do: %{"payment_attempt_id" => id}
  defp worker_args(:reconciliation, id, _now), do: %{"offer_id" => id, "mode" => "dry_run"}
  defp worker_args(:refund_inventory, id, _now), do: %{"refund_id" => id}
  defp worker_args(:paystack_webhook, id, _now), do: %{"payment_event_id" => id}

  defp worker_args(:verify_payment, id, _now),
    do: %{"payment_attempt_id" => id, "payment_event_id" => id}

  defp worker_args(:issue_tickets, id, _now) do
    %{
      "sales_order_id" => id,
      "idempotency_key" => "p1f-fixture-issue-#{id}",
      "correlation_id" => "p1f-#{id}"
    }
  end

  defp worker_args(:ticket_delivery_coordinator, id, _now), do: %{"sales_order_id" => id}

  defp worker_args(:checkout_expiry_sweeper, id, _now),
    do: %{"correlation_id" => "p1f-sweep-#{id}"}

  defp worker_args(:payment_recovery_sweep, _id, _now), do: %{}
  defp worker_args(:checkout_expiry, id, _now), do: %{"checkout_session_id" => id}

  defp worker_args(:whatsapp_inbound, id, _now) do
    %{
      "conversation_id" => id,
      "provider_message_id" => "fixture-provider-message-#{id}",
      "message_type" => "text",
      "correlation_id" => "p1f-inbound-#{id}"
    }
  end

  defp worker_args(:send_whatsapp_payment_link, id, _now) do
    %{"conversation_id" => id, "sales_order_id" => id, "payment_attempt_id" => id}
  end

  defp worker_args(:send_whatsapp_ticket_link, id, _now), do: %{"ticket_delivery_intent_id" => id}

  defp worker_args(:unexpected, id, _now), do: %{"fixture_source" => "p1f", "fixture_id" => id}

  defp attempt_fields(:available, _max_attempts, _timestamp), do: {0, nil, []}
  defp attempt_fields(:scheduled, _max_attempts, _timestamp), do: {0, nil, []}
  defp attempt_fields(:cancelled, _max_attempts, _timestamp), do: {0, nil, []}
  defp attempt_fields(:executing, _max_attempts, _timestamp), do: {1, [@runner], []}

  defp attempt_fields(:retryable, _max_attempts, timestamp) do
    {1, [@runner], [synthetic_error(1, timestamp.attempted_at)]}
  end

  defp attempt_fields(:completed, _max_attempts, _timestamp), do: {1, [@runner], []}

  defp attempt_fields(state, max_attempts, timestamp)
       when state in [:discarded_recent_1h, :discarded_older] do
    errors =
      Enum.map(1..max_attempts, fn attempt ->
        at = DateTime.add(timestamp.inserted_at, 60 * (attempt - 1), :second)
        synthetic_error(attempt, at)
      end)

    {max_attempts, [@runner], errors}
  end

  defp synthetic_error(attempt, at) do
    %{
      "attempt" => attempt,
      "at" => DateTime.to_iso8601(at),
      "error" => "P1F synthetic fixture failure #{attempt}"
    }
  end

  defp oban_state(:discarded_recent_1h), do: "discarded"
  defp oban_state(:discarded_older), do: "discarded"
  defp oban_state(state), do: Atom.to_string(state)

  defp worker_name(%{module: module}), do: Oban.Worker.to_string(module)
  defp worker_name(%{worker_name: worker_name}), do: worker_name

  defp actual_max_attempts(%{module: module}),
    do: module.__opts__() |> Keyword.fetch!(:max_attempts)

  defp actual_max_attempts(%{max_attempts: max_attempts}), do: max_attempts

  defp raw_queue(%{raw_queue: queue}), do: queue
  defp raw_queue(%{queue: queue}), do: queue

  defp state_offsets(scenario_key) do
    Enum.reduce(@states, %{}, fn state, offsets ->
      {per_worker, _next} =
        Enum.map_reduce(@workers, 0, fn worker, current ->
          count = worker.counts |> Map.fetch!(scenario_key) |> Enum.at(state_index(state))
          {{worker.id, current}, current + count}
        end)

      Map.put(offsets, state, Map.new(per_worker))
    end)
  end

  defp state_index(state), do: Enum.find_index(@states, &(&1 == state))

  defp seed(scenario_key_or_name, purpose) do
    scenario_name =
      case Map.fetch(@scenarios, scenario_key_or_name) do
        {:ok, scenario} -> scenario.name
        :error -> scenario_key_or_name
      end

    :crypto.hash(:sha256, "P1F:#{@main_sha}:#{scenario_name}:#{purpose}")
  end
end

P1F.ObanSnapshotFixture.main(System.argv())
