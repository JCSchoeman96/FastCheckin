defmodule FastCheck.Observability do
  @moduledoc """
  Shared observability contracts for FastCheck Sales.

  Provides stable telemetry names, log/Sentry redaction, and correlation helpers
  so Sales, Paystack, WhatsApp, ticketing, delivery, and admin slices emit safe,
  consistent telemetry without leaking PII, tokens, or raw provider payloads.

  Policy references:
  - `docs/fastcheck_sales/security/LOG_REDACTION_POLICY.md`
  - `docs/fastcheck_sales/security/SECURITY_PII_TOKEN_MASTER.md`

  Submodules:
  - `FastCheck.Observability.Redactor`
  - `FastCheck.Observability.TelemetryNames`
  - `FastCheck.Observability.Correlation`
  """

  alias FastCheck.Observability.Correlation
  alias FastCheck.Observability.Redactor
  alias FastCheck.Observability.TelemetryNames

  defdelegate redact_map(map, opts \\ []), to: Redactor
  defdelegate redact_keyword(keyword, opts \\ []), to: Redactor
  defdelegate redact_value(key, value, opts \\ []), to: Redactor
  defdelegate redact_phone(phone), to: Redactor
  defdelegate redact_email(email), to: Redactor
  defdelegate redact_token(token), to: Redactor
  defdelegate redact_url(url), to: Redactor
  defdelegate redact_ticket_code(code), to: Redactor
  defdelegate safe_metadata(metadata), to: Redactor

  defdelegate telemetry_events, to: TelemetryNames, as: :all
  defdelegate ensure_correlation_id(context), to: Correlation
  defdelegate from_logger_metadata(), to: Correlation
  defdelegate for_oban_args(args), to: Correlation
  defdelegate merge_metadata(left, right), to: Correlation
  defdelegate operational_metadata(attrs), to: Correlation
end
