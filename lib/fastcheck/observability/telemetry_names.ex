defmodule FastCheck.Observability.TelemetryNames do
  @moduledoc """
  Approved FastCheck Sales `:telemetry` event names.

  Later Sales slices must use these stable list-style names instead of ad-hoc
  strings. Never build event names from user input.
  """

  @checkout_events [
    [:fastcheck, :sales, :checkout, :reserved],
    [:fastcheck, :sales, :checkout, :expired],
    [:fastcheck, :sales, :checkout, :released]
  ]

  @inventory_events [
    [:fastcheck, :sales, :inventory, :reserved],
    [:fastcheck, :sales, :inventory, :consumed],
    [:fastcheck, :sales, :inventory, :released],
    [:fastcheck, :sales, :inventory, :reconciled]
  ]

  @payment_events [
    [:fastcheck, :sales, :payment, :initialized],
    [:fastcheck, :sales, :payment, :webhook_received],
    [:fastcheck, :sales, :payment, :verified],
    [:fastcheck, :sales, :payment, :mismatch],
    [:fastcheck, :sales, :payment, :failed]
  ]

  @ticket_events [
    [:fastcheck, :sales, :ticket, :issued],
    [:fastcheck, :sales, :ticket, :issue_failed],
    [:fastcheck, :sales, :ticket, :revoked],
    [:fastcheck, :sales, :ticket, :revocation_started],
    [:fastcheck, :sales, :ticket, :revocation_idempotent],
    [:fastcheck, :sales, :ticket, :revocation_failed]
  ]

  @scanner_visibility_events [
    [:fastcheck, :sales, :scanner_visibility, :sync_queued],
    [:fastcheck, :sales, :scanner_visibility, :invalidation_appended]
  ]

  @delivery_events [
    [:fastcheck, :sales, :delivery, :queued],
    [:fastcheck, :sales, :delivery, :sent],
    [:fastcheck, :sales, :delivery, :failed]
  ]

  @whatsapp_events [
    [:fastcheck, :sales, :whatsapp, :inbound_received],
    [:fastcheck, :sales, :whatsapp, :outbound_sent]
  ]

  @manual_review_events [
    [:fastcheck, :sales, :manual_review, :opened],
    [:fastcheck, :sales, :manual_review, :closed]
  ]

  @all_events @checkout_events ++
                @inventory_events ++
                @payment_events ++
                @ticket_events ++
                @scanner_visibility_events ++
                @delivery_events ++
                @whatsapp_events ++
                @manual_review_events

  @doc "Returns all 27 approved Sales telemetry event name lists."
  @spec all() :: [[atom()]]
  def all, do: @all_events

  @doc false
  def checkout_events, do: @checkout_events

  @doc false
  def inventory_events, do: @inventory_events

  @doc false
  def payment_events, do: @payment_events

  @doc false
  def ticket_events, do: @ticket_events

  @doc false
  def scanner_visibility_events, do: @scanner_visibility_events

  @doc false
  def delivery_events, do: @delivery_events

  @doc false
  def whatsapp_events, do: @whatsapp_events

  @doc false
  def manual_review_events, do: @manual_review_events

  @doc false
  def ticket_revocation_started, do: [:fastcheck, :sales, :ticket, :revocation_started]

  @doc false
  def ticket_revoked, do: [:fastcheck, :sales, :ticket, :revoked]

  @doc false
  def ticket_revocation_idempotent, do: [:fastcheck, :sales, :ticket, :revocation_idempotent]

  @doc false
  def ticket_revocation_failed, do: [:fastcheck, :sales, :ticket, :revocation_failed]

  @doc false
  def scanner_visibility_sync_queued, do: [:fastcheck, :sales, :scanner_visibility, :sync_queued]

  @doc false
  def scanner_visibility_invalidation_appended,
    do: [:fastcheck, :sales, :scanner_visibility, :invalidation_appended]
end
