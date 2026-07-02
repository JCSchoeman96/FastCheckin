defmodule FastCheck.Messaging.WhatsApp.CopyTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.Copy

  @protected_fragments [
    "ticket found",
    "order found",
    "match found",
    "pdf",
    "http://",
    "https://",
    "token",
    "paystack",
    "provider",
    "ticket code",
    "delivery"
  ]

  test "resend copy is bilingual and enumeration-safe" do
    af_copy = [
      Copy.text("af", :resend_ticket),
      Copy.text("af", :resend_name),
      Copy.text("af", :resend_email),
      Copy.text("af", :resend_check_email),
      Copy.text("af", :resend_enter_otp),
      Copy.text("af", :resend_invalid_email)
    ]

    en_copy = [
      Copy.text("en", :resend_ticket),
      Copy.text("en", :resend_name),
      Copy.text("en", :resend_email),
      Copy.text("en", :resend_check_email),
      Copy.text("en", :resend_enter_otp),
      Copy.text("en", :resend_invalid_email)
    ]

    assert Enum.join(af_copy, "\n") =~ "e-pos"
    assert Enum.join(en_copy, "\n") =~ "email"
    assert Copy.text("en", :resend_ticket) == "Re-send my ticket"

    for body <- af_copy ++ en_copy do
      downcased = String.downcase(body)

      for fragment <- @protected_fragments do
        refute downcased =~ fragment
      end
    end
  end
end
