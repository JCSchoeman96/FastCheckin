defmodule FastCheck.TickeraCircuitBreaker do
  @moduledoc """
  Circuit breaker GenServer that protects Tickera API integrations from repeated
  failures.

  The server tracks consecutive failures and opens the circuit after the
  configured threshold. Once open it automatically transitions to half-open
  after the timeout window, allowing retries to determine whether the remote
  dependency recovered.
  """

  use GenServer
  require Logger

  @default_failure_threshold 3
  @default_open_timeout 10_000

  @typedoc """
  Internal state of the circuit breaker.
  """
  @type state :: %{
          status: :closed | :open | :half_open,
          failure_count: non_neg_integer(),
          opened_at: integer() | nil,
          timer_ref: reference() | nil,
          failure_threshold: pos_integer(),
          open_timeout: pos_integer()
        }

  ## Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Executes the given `{module, function, args}` tuple under the circuit breaker.

  When the circuit is open all calls return `{:error, :circuit_open}`. Once the
  circuit transitions back to half-open the wrapped call is allowed again.
  """
  @spec call(module(), atom(), list()) :: term()
  def call(module, function, args \\ [])
      when is_atom(module) and is_atom(function) and is_list(args) do
    GenServer.call(__MODULE__, {:execute, module, function, args}, :infinity)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    state = %{
      status: :closed,
      failure_count: 0,
      opened_at: nil,
      timer_ref: nil,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      open_timeout: Keyword.get(opts, :open_timeout, @default_open_timeout)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:execute, _module, _function, _args}, _from, %{status: :open} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call({:execute, module, function, args}, _from, state) do
    case safe_apply(module, function, args) do
      {:ok, result} ->
        if failure_response?(result) do
          {:reply, result, register_failure(state)}
        else
          {:reply, result, register_success(state)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, register_failure(state)}
    end
  end

  @impl true
  def handle_info(:transition_to_half_open, %{status: :open} = state) do
    Logger.info("TickeraCircuitBreaker transitioning to half-open state")
    {:noreply, %{state | status: :half_open, timer_ref: nil, failure_count: 0}}
  end

  def handle_info(:transition_to_half_open, state) do
    {:noreply, state}
  end

  ## Helpers

  defp safe_apply(module, function, args) do
    {:ok, apply(module, function, args)}
  rescue
    exception ->
      Logger.error("TickeraCircuitBreaker wrapped call failed: #{Exception.message(exception)}")
      {:error, {:exception, exception}}
  catch
    kind, reason ->
      Logger.error("TickeraCircuitBreaker caught #{inspect(kind)}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp failure_response?(result) do
    match?({:error, _}, result) or match?({:error, _, _}, result) or result == :error
  end

  defp register_success(%{timer_ref: timer_ref} = state) do
    cancel_timer(timer_ref)
    %{state | status: :closed, failure_count: 0, opened_at: nil, timer_ref: nil}
  end

  defp register_failure(%{status: :half_open} = state) do
    open_circuit(%{state | failure_count: state.failure_count + 1})
  end

  defp register_failure(state) do
    updated_state = %{state | failure_count: state.failure_count + 1}

    if updated_state.failure_count >= updated_state.failure_threshold do
      open_circuit(updated_state)
    else
      updated_state
    end
  end

  defp open_circuit(%{timer_ref: timer_ref} = state) do
    Logger.warning("TickeraCircuitBreaker opening circuit after consecutive failures")

    cancel_timer(timer_ref)
    timer_ref = Process.send_after(self(), :transition_to_half_open, state.open_timeout)

    %{
      state
      | status: :open,
        failure_count: 0,
        opened_at: System.system_time(:millisecond),
        timer_ref: timer_ref
    }
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(timer_ref), do: Process.cancel_timer(timer_ref)
end
