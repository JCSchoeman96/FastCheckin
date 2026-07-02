defmodule FastCheck.Tickets.Resend.Request do
  @moduledoc """
  Input contract and normalization helpers for customer ticket resend requests.

  This module is pure: it does not read/write the database, log, send messages,
  generate PDFs, or call external services.
  """

  @enforce_keys [:name, :email]
  defstruct name: nil,
            email: nil,
            source: %{},
            correlation_id: nil,
            idempotency_key: nil,
            now: nil

  @type source :: %{
          optional(:conversation_id) => integer() | nil,
          optional(:phone_e164) => String.t() | nil,
          optional(:wa_id) => String.t() | nil,
          optional(:ip) => String.t() | nil
        }

  @type t :: %__MODULE__{
          name: term(),
          email: term(),
          source: source() | map() | nil,
          correlation_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          now: DateTime.t() | nil
        }

  @type normalized :: %{
          name: String.t(),
          email: String.t(),
          source: source(),
          correlation_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          now: DateTime.t()
        }

  @email_regex ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/

  @spec normalize(t() | map()) :: {:ok, normalized()} | {:error, :invalid_input}
  def normalize(%__MODULE__{} = request) do
    normalize(Map.from_struct(request))
  end

  def normalize(request) when is_map(request) do
    with {:ok, email} <- normalize_email(Map.get(request, :email) || Map.get(request, "email")),
         {:ok, name} <- normalize_name(Map.get(request, :name) || Map.get(request, "name")) do
      {:ok,
       %{
         email: email,
         name: name,
         source: normalize_source(Map.get(request, :source) || Map.get(request, "source") || %{}),
         correlation_id:
           normalize_optional_string(
             Map.get(request, :correlation_id) || Map.get(request, "correlation_id")
           ),
         idempotency_key:
           normalize_optional_string(
             Map.get(request, :idempotency_key) || Map.get(request, "idempotency_key")
           ),
         now: normalize_now(Map.get(request, :now) || Map.get(request, "now"))
       }}
    else
      {:error, _reason} -> {:error, :invalid_input}
    end
  end

  def normalize(_request), do: {:error, :invalid_input}

  @spec normalize_email(term()) :: {:ok, String.t()} | {:error, :invalid_email}
  def normalize_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if Regex.match?(@email_regex, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_email}
    end
  end

  def normalize_email(_email), do: {:error, :invalid_email}

  @spec normalize_name(term()) :: {:ok, String.t()} | {:error, :invalid_name}
  def normalize_name(name) when is_binary(name) do
    normalized =
      name
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[[:punct:]]+/u, " ")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()

    if String.length(normalized) >= 2 do
      {:ok, normalized}
    else
      {:error, :invalid_name}
    end
  end

  def normalize_name(_name), do: {:error, :invalid_name}

  @spec normalize_source(term()) :: source()
  def normalize_source(source) when is_map(source) do
    %{
      conversation_id: normalize_positive_integer(source_value(source, :conversation_id)),
      phone_e164: normalize_optional_string(source_value(source, :phone_e164)),
      wa_id: normalize_optional_string(source_value(source, :wa_id)),
      ip: normalize_optional_string(source_value(source, :ip))
    }
  end

  def normalize_source(_source), do: %{}

  defp source_value(source, key), do: Map.get(source, key) || Map.get(source, Atom.to_string(key))

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp normalize_now(%DateTime{} = now), do: DateTime.truncate(now, :second)
  defp normalize_now(_now), do: DateTime.utc_now() |> DateTime.truncate(:second)
end
