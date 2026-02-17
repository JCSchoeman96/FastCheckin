defmodule FastCheck.Security.Sanitizer do
  @moduledoc """
  Sanitizes user inputs to prevent XSS attacks and ensure data integrity.

  Strips HTML tags, normalizes whitespace, and validates input length.
  """

  @max_string_length 1000
  @max_name_length 255
  @max_url_length 2048

  @doc """
  Sanitizes a string input by:
  - Stripping HTML tags
  - Normalizing whitespace
  - Truncating to max length
  - Removing control characters
  """
  @spec sanitize_string(String.t() | nil, integer() | nil) :: String.t()
  def sanitize_string(input, max_length \\ @max_string_length)
  def sanitize_string(nil, _max_length), do: ""
  def sanitize_string(input, max_length) when is_binary(input) do
    input
    |> strip_html_tags()
    |> normalize_whitespace()
    |> remove_control_characters()
    |> String.trim()
    |> truncate(max_length)
  end

  def sanitize_string(input, _max_length), do: to_string(input) |> sanitize_string()

  @doc """
  Sanitizes a name field (event name, location, entrance name, etc.)
  """
  @spec sanitize_name(String.t() | nil) :: String.t()
  def sanitize_name(nil), do: ""
  def sanitize_name(name) when is_binary(name) do
    name
    |> strip_html_tags()
    |> normalize_whitespace()
    |> remove_control_characters()
    |> String.trim()
    |> truncate(@max_name_length)
  end

  def sanitize_name(name), do: to_string(name) |> sanitize_name()

  @doc """
  Sanitizes a URL field, ensuring it's a valid URL format.
  """
  @spec sanitize_url(String.t() | nil) :: String.t()
  def sanitize_url(nil), do: ""
  def sanitize_url(url) when is_binary(url) do
    url
    |> String.trim()
    |> strip_html_tags()
    |> truncate(@max_url_length)
  end

  def sanitize_url(url), do: to_string(url) |> sanitize_url()

  @doc """
  Sanitizes an email address.
  """
  @spec sanitize_email(String.t() | nil) :: String.t()
  def sanitize_email(nil), do: ""
  def sanitize_email(email) when is_binary(email) do
    email
    |> String.trim()
    |> String.downcase()
    |> strip_html_tags()
    |> truncate(255)
  end

  def sanitize_email(email), do: to_string(email) |> sanitize_email()

  # Private helpers

  defp strip_html_tags(input) do
    # Remove HTML tags but preserve text content
    Regex.replace(~r/<[^>]*>/, input, "")
  end

  defp normalize_whitespace(input) do
    # Replace multiple whitespace with single space
    Regex.replace(~r/\s+/, input, " ")
  end

  defp remove_control_characters(input) do
    # Remove control characters except newlines, tabs, and carriage returns
    Regex.replace(~r/[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]/, input, "")
  end

  defp truncate(input, max_length) when is_integer(max_length) and max_length > 0 do
    if String.length(input) > max_length do
      String.slice(input, 0, max_length)
    else
      input
    end
  end

  defp truncate(input, _), do: input
end
