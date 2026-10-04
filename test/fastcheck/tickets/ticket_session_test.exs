defmodule FastCheck.Tickets.TicketSessionTest do
  use ExUnit.Case, async: false

  alias FastCheck.Redis.Namespace
  alias FastCheck.Tickets.TicketSession

  @ticket_issue_id 12_345
  @other_ticket_issue_id 67_890
  @delivery_hash_a "delivery-hash-alpha"
  @delivery_hash_b "delivery-hash-beta"

  setup do
    browser_session_id = TicketSession.new_browser_session_id()
    {:ok, browser_session_id: browser_session_id}
  end

  test "new_browser_session_id is URL-safe 32 random bytes without padding" do
    session_id = TicketSession.new_browser_session_id()

    assert byte_size(Base.url_decode64!(session_id, padding: false)) == 32
    refute String.contains?(session_id, "=")
    assert Regex.match?(~r/^[A-Za-z0-9_-]+$/, session_id)
  end

  test "generation_fingerprint is deterministic frozen v1", %{browser_session_id: _session} do
    fp_a = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp_b = TicketSession.generation_fingerprint(@delivery_hash_b)

    expected_a =
      :crypto.hash(:sha256, "ticket-session:v1:" <> @delivery_hash_a)
      |> Base.url_encode64(padding: false)

    assert fp_a == expected_a
    assert fp_a != fp_b
    assert byte_size(fp_a) == 43
  end

  test "registry_key hashes browser session id and applies namespace", %{
    browser_session_id: browser_session_id
  } do
    key = TicketSession.registry_key(browser_session_id)

    refute String.contains?(key, browser_session_id)

    case Namespace.namespace() do
      nil -> assert String.starts_with?(key, "ticket-browser-session:")
      namespace -> assert String.starts_with?(key, namespace <> ":ticket-browser-session:")
    end
  end

  test "empty bind stores BOUND with generation fingerprint only", %{
    browser_session_id: browser_session_id
  } do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)

    assert {:ok, :bound} =
             TicketSession.bind(
               browser_session_id,
               @ticket_issue_id,
               1,
               fingerprint,
               TicketSession.session_idle_ttl_seconds()
             )

    assert {:ok, binding} = TicketSession.fetch_binding(browser_session_id, @ticket_issue_id)
    assert binding.generation == 1
    assert binding.fingerprint == fingerprint
    assert binding.encoded == "v1:1:#{fingerprint}"

    stored = redis_hget!(browser_session_id, @ticket_issue_id)
    refute String.contains?(stored, @delivery_hash_a)
    refute String.contains?(stored, browser_session_id)
  end

  test "forward bind G1 to G2 leaves final generation at G2", %{browser_session_id: session} do
    fp1 = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp2 = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fp1, 86_400)
    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fp2, 86_400)

    assert {:ok, %{generation: 2, fingerprint: expected_fp}} =
             TicketSession.fetch_binding(session, @ticket_issue_id)

    assert expected_fp == fp2
  end

  test "deterministic forward order rejects late stale G1 after G2 is stored", %{
    browser_session_id: session
  } do
    fp1 = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp2 = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fp1, 86_400)
    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fp2, 86_400)

    assert {:error, :stale_generation} =
             TicketSession.bind(session, @ticket_issue_id, 1, fp1, 86_400)

    assert {:ok, %{generation: 2}} = TicketSession.fetch_binding(session, @ticket_issue_id)
  end

  test "idempotent bind with same generation and fingerprint refreshes TTL", %{
    browser_session_id: session
  } do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fingerprint, 30)
    short_ttl = redis_ttl!(session)
    assert short_ttl > 0 and short_ttl <= 30

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fingerprint, 86_400)

    refreshed_ttl = redis_ttl!(session)
    assert refreshed_ttl > short_ttl
    assert refreshed_ttl in 86_300..86_400
  end

  test "stale bind does not refresh TTL", %{browser_session_id: session} do
    fp1 = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp2 = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fp2, 25)
    short_ttl = redis_ttl!(session)

    assert {:error, :stale_generation} =
             TicketSession.bind(session, @ticket_issue_id, 1, fp1, 86_400)

    assert redis_ttl!(session) == short_ttl
  end

  test "generation conflict is fail-closed without TTL refresh", %{browser_session_id: session} do
    fp_a = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp_b = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fp_a, 20)
    short_ttl = redis_ttl!(session)

    assert {:error, :generation_conflict} =
             TicketSession.bind(session, @ticket_issue_id, 2, fp_b, 86_400)

    assert {:ok, %{fingerprint: ^fp_a}} = TicketSession.fetch_binding(session, @ticket_issue_id)
    assert redis_ttl!(session) == short_ttl
  end

  test "successful bind sets positive TTL near session idle TTL", %{browser_session_id: session} do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)

    assert {:ok, :bound} =
             TicketSession.bind(session, @ticket_issue_id, 1, fingerprint, 86_400)

    ttl = redis_ttl!(session)
    assert ttl in 86_300..86_400
  end

  test "exact compare-delete removes observed binding", %{browser_session_id: session} do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fingerprint, 86_400)
    assert {:ok, binding} = TicketSession.fetch_binding(session, @ticket_issue_id)

    assert {:ok, :removed} =
             TicketSession.conditional_remove(session, @ticket_issue_id, binding.encoded)

    assert {:error, :not_found} = TicketSession.fetch_binding(session, @ticket_issue_id)
  end

  test "stale compare-delete preserves newer binding", %{browser_session_id: session} do
    fp1 = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp2 = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fp1, 86_400)
    assert {:ok, g1_binding} = TicketSession.fetch_binding(session, @ticket_issue_id)
    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 2, fp2, 86_400)

    assert {:ok, :not_removed} =
             TicketSession.conditional_remove(session, @ticket_issue_id, g1_binding.encoded)

    assert {:ok, %{generation: 2, fingerprint: ^fp2}} =
             TicketSession.fetch_binding(session, @ticket_issue_id)
  end

  test "compare-delete for one ticket does not modify another ticket field", %{
    browser_session_id: session
  } do
    fp_a = TicketSession.generation_fingerprint(@delivery_hash_a)
    fp_b = TicketSession.generation_fingerprint(@delivery_hash_b)

    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fp_a, 86_400)
    assert {:ok, :bound} = TicketSession.bind(session, @other_ticket_issue_id, 1, fp_b, 86_400)
    assert {:ok, binding_a} = TicketSession.fetch_binding(session, @ticket_issue_id)

    assert {:ok, :removed} =
             TicketSession.conditional_remove(session, @ticket_issue_id, binding_a.encoded)

    assert {:error, :not_found} = TicketSession.fetch_binding(session, @ticket_issue_id)
    assert {:ok, %{generation: 1}} = TicketSession.fetch_binding(session, @other_ticket_issue_id)
  end

  test "refresh_ttl_if_exists refreshes existing session and does not create missing key", %{
    browser_session_id: session
  } do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)
    assert {:ok, :bound} = TicketSession.bind(session, @ticket_issue_id, 1, fingerprint, 30)
    short_ttl = redis_ttl!(session)

    assert {:ok, :refreshed} = TicketSession.refresh_ttl_if_exists(session, 86_400)
    assert redis_ttl!(session) > short_ttl

    missing_session = TicketSession.new_browser_session_id()
    refute Process.whereis(FastCheck.Redix) == nil

    assert {:ok, :missing} = TicketSession.refresh_ttl_if_exists(missing_session, 86_400)
    refute redis_key_exists?(missing_session)
  end

  test "missing redis process returns registry_unavailable" do
    fingerprint = TicketSession.generation_fingerprint(@delivery_hash_a)
    session_id = TicketSession.new_browser_session_id()

    assert {:error, :registry_unavailable} =
             TicketSession.bind(session_id, @ticket_issue_id, 1, fingerprint, 86_400,
               redix_name: :ticket_session_missing_redix
             )

    assert {:error, :registry_unavailable} =
             TicketSession.fetch_binding(session_id, @ticket_issue_id,
               redix_name: :ticket_session_missing_redix
             )
  end

  test "fetch_binding rejects malformed stored values", %{browser_session_id: session} do
    key = TicketSession.registry_key(session)
    field = "ticket:#{@ticket_issue_id}"

    assert {:ok, 1} = Redix.command(FastCheck.Redix, ["HSET", key, field, "not-a-binding"])
    assert {:error, :invalid_binding} = TicketSession.fetch_binding(session, @ticket_issue_id)
  end

  defp redis_hget!(browser_session_id, ticket_issue_id) do
    key = TicketSession.registry_key(browser_session_id)
    field = "ticket:#{ticket_issue_id}"

    {:ok, value} = Redix.command(FastCheck.Redix, ["HGET", key, field])
    value
  end

  defp redis_ttl!(browser_session_id) do
    key = TicketSession.registry_key(browser_session_id)

    {:ok, ttl} = Redix.command(FastCheck.Redix, ["TTL", key])
    ttl
  end

  defp redis_key_exists?(browser_session_id) do
    key = TicketSession.registry_key(browser_session_id)

    case Redix.command(FastCheck.Redix, ["EXISTS", key]) do
      {:ok, 1} -> true
      _ -> false
    end
  end
end
