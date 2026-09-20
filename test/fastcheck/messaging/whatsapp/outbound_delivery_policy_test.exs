defmodule FastCheck.Messaging.WhatsApp.OutboundDeliveryPolicyTest do
  use ExUnit.Case, async: true

  alias FastCheck.Messaging.WhatsApp.OutboundDeliveryPolicy
  alias FastCheck.Messaging.WhatsApp.Response

  describe "classify/1" do
    test "classifies 429 rate limit as safe_retry" do
      response = %Response{
        provider: :meta,
        status: :rate_limited,
        raw_status: 429,
        retryable?: true,
        rate_limited?: true,
        provider_error_code: "131000",
        provider_error_message: "rate limit"
      }

      assert OutboundDeliveryPolicy.classify(response) == :safe_retry
      assert OutboundDeliveryPolicy.classify({:error, response}) == :safe_retry
    end

    test "classifies timeout as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :timeout,
        retryable?: true,
        provider_error_message: "timeout"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review
    end

    test "classifies transport error as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :transport_error,
        retryable?: true,
        provider_error_message: "connection reset"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review
    end

    test "classifies 500 server error as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :server_error,
        raw_status: 500,
        retryable?: true,
        provider_error_code: "131000",
        provider_error_message: "internal error"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review
    end

    test "classifies 503 server error as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :server_error,
        raw_status: 503,
        retryable?: true,
        provider_error_code: "131000",
        provider_error_message: "service unavailable"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review
    end

    test "classifies 5xx decode failure as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :unknown_error,
        raw_status: 502,
        retryable?: true,
        provider_error_message: "failed to decode json"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review
    end

    test "classifies 2xx success response without usable WAMID as ambiguous_manual_review" do
      response = %Response{
        provider: :meta,
        status: :unknown_error,
        raw_status: 200,
        provider_message_id: nil,
        retryable?: false,
        provider_error_message: "meta response did not include message id"
      }

      assert OutboundDeliveryPolicy.classify(response) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :ambiguous_manual_review

      empty_wamid_response = %Response{
        provider: :meta,
        status: :unknown_error,
        raw_status: 200,
        provider_message_id: "  ",
        retryable?: false,
        provider_error_message: "meta response did not include message id"
      }

      assert OutboundDeliveryPolicy.classify(empty_wamid_response) == :ambiguous_manual_review
    end

    test "classifies 400 validation error as permanent_manual_review" do
      response = %Response{
        provider: :meta,
        status: :validation_error,
        raw_status: 400,
        retryable?: false,
        provider_error_code: "100",
        provider_error_message: "invalid parameter"
      }

      assert OutboundDeliveryPolicy.classify(response) == :permanent_manual_review
      assert OutboundDeliveryPolicy.classify({:error, response}) == :permanent_manual_review
    end

    test "classifies 401 and 403 auth errors as permanent_manual_review" do
      for status <- [401, 403] do
        response = %Response{
          provider: :meta,
          status: :auth_error,
          raw_status: status,
          retryable?: false,
          provider_error_code: "190",
          provider_error_message: "bad token"
        }

        assert OutboundDeliveryPolicy.classify(response) == :permanent_manual_review
        assert OutboundDeliveryPolicy.classify({:error, response}) == :permanent_manual_review
      end
    end

    test "classifies missing_config as permanent_manual_review" do
      response = %Response{
        provider: :meta,
        status: :missing_config,
        retryable?: false,
        provider_error_message: "missing WhatsApp access token"
      }

      assert OutboundDeliveryPolicy.classify(response) == :permanent_manual_review
    end

    test "classifies non-retryable 4xx as permanent_manual_review" do
      response = %Response{
        provider: :meta,
        status: :unknown_error,
        raw_status: 418,
        retryable?: false,
        provider_error_message: "provider rejected"
      }

      assert OutboundDeliveryPolicy.classify(response) == :permanent_manual_review
    end

    test "defaults unknown error results to ambiguous_manual_review" do
      assert OutboundDeliveryPolicy.classify(%Response{
               provider: :meta,
               status: :unexpected_provider_state,
               retryable?: false
             }) == :ambiguous_manual_review

      assert OutboundDeliveryPolicy.classify({:error, :network_down}) == :ambiguous_manual_review
      assert OutboundDeliveryPolicy.classify(:unknown) == :ambiguous_manual_review
    end
  end
end
