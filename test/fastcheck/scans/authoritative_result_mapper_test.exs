defmodule FastCheck.Scans.AuthoritativeResultMapperTest do
  use ExUnit.Case, async: true

  alias FastCheck.Scans.AuthoritativeResultMapper
  alias FastCheck.Scans.Result

  test "maps final replay duplicates to duplicate with replay reason code" do
    result = base_result(%{delivery_state: :final_acknowledged, reason_code: "SUCCESS"})

    assert %{
             idempotency_key: "idem-1",
             status: "duplicate",
             message: "Already processed: Check-in successful",
             reason_code: "replay_duplicate"
           } = AuthoritativeResultMapper.to_api_result(result)
  end

  test "maps business duplicates to error with business_duplicate reason code" do
    result =
      base_result(%{
        status: "error",
        reason_code: "DUPLICATE",
        message: "Already checked in: Already checked in at 2026-03-23T07:00:00Z"
      })

    assert %{
             idempotency_key: "idem-1",
             status: "error",
             message: "Already checked in: Already checked in at 2026-03-23T07:00:00Z",
             reason_code: "business_duplicate"
           } = AuthoritativeResultMapper.to_api_result(result)
  end

  test "maps payment invalid to error with payment_invalid reason code" do
    result =
      base_result(%{
        status: "error",
        reason_code: "PAYMENT_INVALID",
        message: "Payment invalid: Entry denied"
      })

    assert %{
             idempotency_key: "idem-1",
             status: "error",
             message: "Payment invalid: Entry denied",
             reason_code: "payment_invalid"
           } = AuthoritativeResultMapper.to_api_result(result)
  end

  test "maps success without a reason code" do
    result = base_result(%{reason_code: "SUCCESS"})

    assert %{idempotency_key: "idem-1", status: "success", message: "Check-in successful"} =
             mapped = AuthoritativeResultMapper.to_api_result(result)

    refute Map.has_key?(mapped, :reason_code)
  end

  test "maps generic errors without a reason code" do
    result =
      base_result(%{
        status: "error",
        reason_code: "INVALID",
        message: "Ticket not found"
      })

    assert %{
             idempotency_key: "idem-1",
             status: "error",
             message: "Ticket not found"
           } =
             mapped = AuthoritativeResultMapper.to_api_result(result)

    refute Map.has_key?(mapped, :reason_code)
  end

  defp base_result(attrs) do
    Result
    |> struct!(%{
      event_id: 1,
      attendee_id: 2,
      idempotency_key: "idem-1",
      ticket_code: "TEST001",
      direction: "in",
      status: "success",
      reason_code: "SUCCESS",
      message: "Check-in successful",
      entrance_name: "Main Gate",
      operator_name: "Scanner 1",
      scanned_at: ~U[2026-03-23 07:00:00Z],
      processed_at: ~U[2026-03-23 07:00:00Z],
      delivery_state: :new_staged,
      hot_state_version: "v1",
      metadata: %{}
    })
    |> Map.from_struct()
    |> Map.merge(attrs)
    |> then(&struct!(Result, &1))
  end
end
