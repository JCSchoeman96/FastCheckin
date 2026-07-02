defmodule FastCheck.Tickets.Resend.EmailOtpRendererTest do
  use ExUnit.Case, async: true

  alias FastCheck.Tickets.Resend.EmailOtpRenderer

  test "renders a generic verification subject" do
    assert EmailOtpRenderer.subject() == "Your FastCheck verification code"
  end

  test "renders text and html bodies with otp and ttl only" do
    otp = "123456"
    ttl_minutes = 10

    text = EmailOtpRenderer.text_body(otp, ttl_minutes)
    html = EmailOtpRenderer.html_body(otp, ttl_minutes)
    subject = EmailOtpRenderer.subject()

    for rendered <- [text, html] do
      assert rendered =~ otp
      assert rendered =~ Integer.to_string(ttl_minutes)
      assert rendered =~ "verification code"

      refute String.downcase(rendered) =~ "payment"
      refute String.downcase(rendered) =~ "paystack"
      refute String.downcase(rendered) =~ "token"
      refute String.downcase(rendered) =~ "qr"
      refute String.downcase(rendered) =~ "whatsapp"
      refute rendered =~ "http://"
      refute rendered =~ "https://"
      refute rendered =~ "+27"
    end

    refute String.downcase(subject) =~ "payment"
    refute String.downcase(subject) =~ "token"
    refute String.downcase(subject) =~ "qr"
    refute String.downcase(subject) =~ "whatsapp"
  end
end
