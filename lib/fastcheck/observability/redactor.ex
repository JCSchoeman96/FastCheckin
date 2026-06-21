defmodule FastCheck.Observability.Redactor do
  @moduledoc """
  Pure redaction helpers for FastCheck Sales observability.

  Filters PII, tokens, provider secrets, payment URLs, and raw provider payloads
  from logs, telemetry metadata, and Sentry-bound structures. Aligns with
  `docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md`.
  """

  @filtered "[FILTERED]"
  @filtered_phone "[FILTERED_PHONE]"
  @filtered_message "[FILTERED_MESSAGE]"

  @max_depth 10

  @forbidden_metadata_keys MapSet.new([
                             :buyer_email,
                             :buyer_phone,
                             :buyer_name,
                             :phone_e164,
                             :recipient,
                             :authorization_url,
                             :access_code,
                             :delivery_token,
                             :delivery_token_hash,
                             :qr_token,
                             :qr_token_hash,
                             :raw_payload,
                             :raw_verify_response,
                             :raw_initialize_response,
                             :message_body,
                             :wa_message_body,
                             :meta_access_token,
                             :paystack_secret_key,
                             :hold_token,
                             :idempotency_key,
                             "buyer_email",
                             "buyer_phone",
                             "buyer_name",
                             "phone_e164",
                             "recipient",
                             "authorization_url",
                             "access_code",
                             "delivery_token",
                             "delivery_token_hash",
                             "qr_token",
                             "qr_token_hash",
                             "raw_payload",
                             "raw_verify_response",
                             "raw_initialize_response",
                             "message_body",
                             "wa_message_body",
                             "meta_access_token",
                             "paystack_secret_key",
                             "hold_token",
                             "idempotency_key"
                           ])

  @sensitive_keys MapSet.new([
                    :buyer_email,
                    :buyer_phone,
                    :buyer_name,
                    :phone_e164,
                    :recipient,
                    :authorization_url,
                    :access_code,
                    :delivery_token,
                    :delivery_token_hash,
                    :qr_token,
                    :qr_token_hash,
                    :raw_payload,
                    :raw_verify_response,
                    :raw_initialize_response,
                    :provider_payload,
                    :message_body,
                    :wa_message_body,
                    :meta_access_token,
                    :paystack_secret,
                    :paystack_secret_key,
                    :whatsapp_verify_token,
                    :app_secret,
                    :hold_token,
                    :password,
                    :secret,
                    :cookie,
                    "buyer_email",
                    "buyer_phone",
                    "buyer_name",
                    "phone_e164",
                    "recipient",
                    "authorization_url",
                    "access_code",
                    "delivery_token",
                    "delivery_token_hash",
                    "qr_token",
                    "qr_token_hash",
                    "raw_payload",
                    "raw_verify_response",
                    "raw_initialize_response",
                    "provider_payload",
                    "message_body",
                    "wa_message_body",
                    "meta_access_token",
                    "paystack_secret",
                    "paystack_secret_key",
                    "whatsapp_verify_token",
                    "app_secret",
                    "hold_token",
                    "password",
                    "secret",
                    "cookie",
                    "idempotency_key"
                  ])

  @safe_id_keys MapSet.new([
                  :order_id,
                  :order_public_reference,
                  :payment_attempt_id,
                  :payment_event_id,
                  :ticket_issue_id,
                  :delivery_attempt_id,
                  :checkout_session_id,
                  :conversation_id,
                  :event_id,
                  :correlation_id,
                  :request_id,
                  :entity_id,
                  :actor_id,
                  :provider_reference_redacted,
                  :ticket_code_redacted,
                  :status,
                  :reason_code,
                  :result,
                  :error_code,
                  "order_id",
                  "order_public_reference",
                  "payment_attempt_id",
                  "payment_event_id",
                  "ticket_issue_id",
                  "delivery_attempt_id",
                  "checkout_session_id",
                  "conversation_id",
                  "event_id",
                  "correlation_id",
                  "request_id",
                  "entity_id",
                  "actor_id",
                  "provider_reference_redacted",
                  "ticket_code_redacted",
                  "status",
                  "reason_code",
                  "result",
                  "error_code"
                ])

  @type redact_opts :: [preserve_safe_ids: boolean(), depth: non_neg_integer()]

  @doc false
  def filtered, do: @filtered

  @doc false
  def filtered_phone, do: @filtered_phone

  @doc false
  def filtered_message, do: @filtered_message

  @spec redact_map(map(), redact_opts()) :: map()
  def redact_map(map, opts \\ []) when is_map(map) do
    redact_map(map, Keyword.get(opts, :depth, 0), opts)
  end

  @spec redact_keyword(keyword(), redact_opts()) :: keyword()
  def redact_keyword(keyword, opts \\ []) when is_list(keyword) do
    keyword
    |> Enum.map(fn {key, value} -> {key, redact_value(key, value, opts)} end)
  end

  @spec redact_value(term(), term(), redact_opts()) :: term()
  def redact_value(key, value, opts \\ [])

  def redact_value(key, value, opts) when is_map(value) do
    depth = Keyword.get(opts, :depth, 0)

    cond do
      preserve_safe_ids?(opts) and safe_id_key?(key) ->
        value

      depth >= @max_depth ->
        @filtered

      sensitive_key?(key) and opaque_value_key?(key) ->
        @filtered

      true ->
        redact_map(value, depth: depth + 1, preserve_safe_ids: preserve_safe_ids?(opts))
    end
  end

  def redact_value(key, value, opts) when is_list(value) do
    depth = Keyword.get(opts, :depth, 0)

    if depth >= @max_depth do
      @filtered
    else
      Enum.map(value, fn
        item when is_map(item) ->
          redact_map(item, depth: depth + 1, preserve_safe_ids: preserve_safe_ids?(opts))

        item when is_list(item) ->
          redact_value(key, item, depth: depth + 1, preserve_safe_ids: preserve_safe_ids?(opts))

        item ->
          item
      end)
    end
  end

  def redact_value(key, value, opts) do
    cond do
      preserve_safe_ids?(opts) and safe_id_key?(key) ->
        value

      sensitive_key?(key) ->
        redact_by_key(key, value)

      true ->
        value
    end
  end

  @spec redact_phone(String.t() | nil) :: String.t()
  def redact_phone(nil), do: @filtered_phone

  def redact_phone(phone) when is_binary(phone) do
    trimmed = String.trim(phone)

    cond do
      trimmed == "" ->
        @filtered_phone

      String.starts_with?(trimmed, "+") and String.length(trimmed) > 6 ->
        prefix = String.slice(trimmed, 0, 3)
        suffix = String.slice(trimmed, -4, 4)
        prefix <> "***" <> suffix

      String.length(trimmed) > 4 ->
        "***" <> String.slice(trimmed, -4, 4)

      true ->
        @filtered_phone
    end
  end

  def redact_phone(_), do: @filtered_phone

  @spec redact_email(String.t() | nil) :: String.t()
  def redact_email(nil), do: @filtered

  def redact_email(email) when is_binary(email) do
    case String.split(email, "@", parts: 2) do
      [_local, domain] when domain != "" ->
        "j***@#{domain}"

      _ ->
        @filtered
    end
  end

  def redact_email(_), do: @filtered

  @spec redact_token(String.t() | nil) :: String.t()
  def redact_token(_), do: @filtered

  @spec redact_url(String.t() | nil) :: String.t()
  def redact_url(nil), do: @filtered

  def redact_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    if trimmed == "" do
      @filtered
    else
      classify_and_redact_url(trimmed)
    end
  rescue
    _ -> @filtered
  end

  def redact_url(_), do: @filtered

  @spec redact_ticket_code(String.t() | nil) :: String.t()
  def redact_ticket_code(nil), do: @filtered

  def redact_ticket_code(code) when is_binary(code) do
    if String.length(code) <= 4 do
      @filtered
    else
      "***" <> String.slice(code, -4, 4)
    end
  end

  def redact_ticket_code(_), do: @filtered

  @doc """
  Returns metadata safe for nested maps (e.g. StateTransition metadata).

  Drops forbidden keys and `idempotency_key` by default. Use bounded Logger
  metadata at request/worker boundaries when `idempotency_key` is required.
  """
  @spec safe_metadata(map() | keyword()) :: map()
  def safe_metadata(metadata) when is_list(metadata), do: metadata |> Map.new() |> safe_metadata()

  def safe_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {key, _value} -> MapSet.member?(@forbidden_metadata_keys, key) end)
    |> Map.new()
    |> redact_map()
  end

  defp redact_map(map, depth, opts) do
    Enum.into(map, %{}, fn {key, value} ->
      {key, redact_value(key, value, depth: depth, preserve_safe_ids: preserve_safe_ids?(opts))}
    end)
  end

  defp redact_by_key(key, value) do
    normalized = normalize_key(key)

    cond do
      normalized in ["buyer_phone", "phone_e164", "recipient"] ->
        redact_phone(to_string(value))

      normalized in ["buyer_email"] ->
        redact_email(to_string(value))

      normalized in ["message_body", "wa_message_body"] ->
        @filtered_message

      normalized in ["authorization_url"] ->
        redact_url(to_string(value))

      normalized in ["buyer_name"] ->
        @filtered

      true ->
        @filtered
    end
  end

  defp sensitive_key?(key) do
    MapSet.member?(@sensitive_keys, key) or sensitive_substring_key?(key)
  end

  defp sensitive_substring_key?(key) do
    normalized = normalize_key(key)

    normalized in ["password", "encrypt"] or
      String.contains?(normalized, [
        "paystack_secret",
        "meta_access_token",
        "whatsapp_verify_token",
        "app_secret",
        "delivery_token",
        "qr_token",
        "raw_payload",
        "raw_verify_response",
        "raw_initialize_response",
        "provider_payload",
        "authorization_url",
        "access_code"
      ])
  end

  defp safe_id_key?(key), do: MapSet.member?(@safe_id_keys, key)

  defp opaque_value_key?(key) do
    normalize_key(key) in [
      "raw_payload",
      "raw_verify_response",
      "raw_initialize_response",
      "delivery_token",
      "delivery_token_hash",
      "qr_token",
      "qr_token_hash",
      "hold_token",
      "access_code",
      "meta_access_token",
      "paystack_secret_key",
      "paystack_secret",
      "whatsapp_verify_token",
      "app_secret",
      "message_body",
      "wa_message_body",
      "buyer_name",
      "buyer_email",
      "buyer_phone",
      "phone_e164",
      "recipient",
      "idempotency_key"
    ]
  end

  defp normalize_key(key) when is_atom(key), do: key |> Atom.to_string() |> String.downcase()
  defp normalize_key(key) when is_binary(key), do: String.downcase(key)
  defp normalize_key(key), do: key |> to_string() |> String.downcase()

  defp preserve_safe_ids?(opts), do: Keyword.get(opts, :preserve_safe_ids, false)

  @sensitive_query_param_names MapSet.new([
                                 "token",
                                 "access_code",
                                 "authorization_url",
                                 "delivery_token",
                                 "qr_token",
                                 "session_key",
                                 "trxref",
                                 "reference",
                                 "signature",
                                 "client_secret",
                                 "app_secret",
                                 "paystack_signature",
                                 "code"
                               ])

  @sensitive_path_pattern ~r/(?:tickets?|deliveries|delivery|payments?|checkout|authorize|secure-ticket|ticket-page|customer-portal)(?:\/|$)/i
  @secure_ticket_path_pattern ~r/^\/t\/.+/

  @sensitive_host_fragments [
    "paystack.com",
    "checkout.paystack",
    "graph.facebook.com",
    "whatsapp.com"
  ]

  defp classify_and_redact_url(url) do
    uri = URI.parse(url)

    cond do
      sensitive_query_params?(uri.query) -> @filtered
      sensitive_host?(uri.host) -> @filtered
      sensitive_path?(uri.path) -> @filtered
      opaque_token_path?(uri.path) -> @filtered
      not classifiable_uri?(uri) -> @filtered
      true -> rebuild_without_query(uri)
    end
  end

  defp sensitive_query_params?(nil), do: false

  defp sensitive_query_params?(query) when is_binary(query) do
    query
    |> URI.decode_query()
    |> Map.keys()
    |> Enum.any?(&sensitive_query_param_name?/1)
  rescue
    _ -> true
  end

  defp sensitive_query_param_name?(name) when is_binary(name) do
    normalized = String.downcase(name)

    MapSet.member?(@sensitive_query_param_names, normalized) or
      String.contains?(normalized, ["token", "secret", "signature", "session"])
  end

  defp sensitive_host?(nil), do: false

  defp sensitive_host?(host) when is_binary(host) do
    normalized = String.downcase(host)

    Enum.any?(@sensitive_host_fragments, &String.contains?(normalized, &1))
  end

  defp sensitive_path?(nil), do: false

  defp sensitive_path?(path) when is_binary(path) do
    String.match?(path, @sensitive_path_pattern) or
      String.match?(path, @secure_ticket_path_pattern)
  end

  defp opaque_token_path?(nil), do: false

  defp opaque_token_path?(path) when is_binary(path) do
    path
    |> String.split("/", trim: true)
    |> Enum.any?(&opaque_path_segment?/1)
  end

  defp opaque_path_segment?(segment) do
    String.length(segment) >= 16 and not numeric_segment?(segment)
  end

  defp numeric_segment?(segment) do
    String.match?(segment, ~r/^\d+$/)
  end

  defp classifiable_uri?(%URI{scheme: scheme, host: host, path: path})
       when scheme in ["http", "https"] do
    is_binary(host) and host != "" and is_binary(path)
  end

  defp classifiable_uri?(%URI{scheme: nil, path: path}) when is_binary(path) and path != "" do
    String.starts_with?(path, "/")
  end

  defp classifiable_uri?(_), do: false

  defp rebuild_without_query(%URI{} = uri) do
    uri
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end
end
