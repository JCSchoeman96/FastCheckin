defmodule FastCheck.Tickets.Resend.Hash do
  @moduledoc """
  Deterministic HMAC-SHA256 helpers for ticket resend lookup material.

  Uses only `config :fastcheck, :ticket_resend, hash_pepper: ...`. The resend
  pepper is intentionally separate from ticket delivery/QR token peppers.
  """

  @spec email(String.t()) :: String.t()
  def email(normalized_email), do: hmac("email", normalized_email)

  @spec name(String.t()) :: String.t()
  def name(normalized_name), do: hmac("name", normalized_name)

  @spec source(map()) :: String.t() | nil
  def source(source) when is_map(source) do
    cond do
      is_integer(source[:conversation_id]) ->
        hmac("source", "conversation:#{source[:conversation_id]}")

      present?(source[:phone_e164]) ->
        hmac("source", "phone:#{source[:phone_e164]}")

      present?(source[:wa_id]) ->
        hmac("source", "wa:#{source[:wa_id]}")

      present?(source[:ip]) ->
        hmac("source", "ip:#{source[:ip]}")

      true ->
        nil
    end
  end

  def source(_source), do: nil

  @spec candidate(integer(), integer()) :: String.t()
  def candidate(sales_order_id, ticket_issue_id) do
    hmac("candidate", "order:#{sales_order_id}:ticket:#{ticket_issue_id}")
  end

  @spec otp(String.t(), String.t()) :: String.t()
  def otp(public_id, otp), do: hmac("otp", "#{public_id}:#{otp}")

  @spec hmac(String.t(), String.t()) :: String.t()
  def hmac(namespace, value) when is_binary(namespace) and is_binary(value) do
    :crypto.mac(:hmac, :sha256, pepper!(), "#{namespace}:#{value}")
    |> Base.encode16(case: :lower)
  end

  defp pepper! do
    :fastcheck
    |> Application.fetch_env!(:ticket_resend)
    |> Keyword.fetch!(:hash_pepper)
    |> case do
      pepper when is_binary(pepper) and byte_size(pepper) > 0 ->
        pepper

      _other ->
        raise KeyError, key: :hash_pepper, term: Application.get_env(:fastcheck, :ticket_resend)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
