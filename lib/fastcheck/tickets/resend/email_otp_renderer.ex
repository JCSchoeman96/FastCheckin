defmodule FastCheck.Tickets.Resend.EmailOtpRenderer do
  @moduledoc """
  Renders minimal, generic email copy for ticket resend OTP verification.
  """

  @subject "Your FastCheck verification code"

  @spec subject() :: binary()
  def subject, do: @subject

  @spec text_body(binary(), pos_integer()) :: binary()
  def text_body(otp, ttl_minutes)
      when is_binary(otp) and is_integer(ttl_minutes) and ttl_minutes > 0 do
    """
    Your FastCheck verification code is: #{otp}

    This code expires in #{ttl_minutes} minutes.

    If you did not request this, you can ignore this email.
    """
  end

  @spec html_body(binary(), pos_integer()) :: binary()
  def html_body(otp, ttl_minutes)
      when is_binary(otp) and is_integer(ttl_minutes) and ttl_minutes > 0 do
    """
    <p>Your FastCheck verification code is: <strong>#{otp}</strong></p>
    <p>This code expires in #{ttl_minutes} minutes.</p>
    <p>If you did not request this, you can ignore this email.</p>
    """
  end
end
