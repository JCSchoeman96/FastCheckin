defmodule FastCheck.Mobile.MobileIdempotencyLog do
  @moduledoc """
  Schema for the mobile_idempotency_log table.

  This table ensures that each scan from a mobile client is processed at most
  once per event, even under retries or network issues. Each unique scan is
  identified by the combination of (event_id, idempotency_key).

  ## Purpose

  Mobile devices may upload the same scan multiple times due to:
  - Network failures and automatic retries
  - User-initiated retries
  - Offline queue processing after connectivity restoration

  The unique index on (event_id, idempotency_key) prevents duplicate processing.
  When a duplicate is detected, the stored result is returned to the client.

  ## Fields

  - `idempotency_key` - Client-generated unique identifier for this scan
  - `event_id` - The event this scan belongs to (foreign key)
  - `ticket_code` - The ticket that was scanned
  - `result` - The outcome of processing (success, error, duplicate, etc.)
  - `metadata` - Additional data (error messages, timestamps, etc.)

  ## Usage

  The SyncController uses this schema to:
  1. Attempt to insert a new idempotency record before processing
  2. If insert succeeds → process the scan and update the result
  3. If unique constraint violation → return the previously stored result
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias FastCheck.Events.Event

  schema "mobile_idempotency_log" do
    field :idempotency_key, :string
    field :ticket_code, :string
    field :result, :string
    field :metadata, :map

    belongs_to :event, Event

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating an idempotency log entry.

  Required fields: idempotency_key, event_id, ticket_code, result
  """
  def changeset(log, attrs) do
    log
    |> cast(attrs, [:idempotency_key, :event_id, :ticket_code, :result, :metadata])
    |> validate_required([:idempotency_key, :event_id, :ticket_code, :result])
    |> unique_constraint([:event_id, :idempotency_key],
      name: :idx_mobile_idempotency_event_key
    )
  end
end
