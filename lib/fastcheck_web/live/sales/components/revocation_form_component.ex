defmodule FastCheckWeb.Sales.Components.RevocationFormComponent do
  @moduledoc """
  Shared destructive-action form for Sales admin revoke/refund operations.
  """

  use FastCheckWeb, :html

  attr :id, :string, required: true
  attr :action, :string, required: true
  attr :submit_label, :string, required: true
  attr :ticket_issue_id, :integer, default: nil
  attr :show_bulk_confirmation, :boolean, default: false
  attr :show_password, :boolean, default: false
  attr :issued_count, :integer, default: 0

  def revocation_form(assigns) do
    ~H"""
    <.form for={%{}} as={:admin_action} id={@id} phx-submit={@action} class="space-y-3">
      <p class="text-sm text-amber-700">
        This will make the ticket non-scannable.
      </p>
      <div :if={@show_bulk_confirmation}>
        <p class="text-sm text-fc-text-secondary">
          {issued_count_preview(@issued_count)} ticket(s) will be revoked.
        </p>
        <label class="flex items-center gap-2 text-sm">
          <input type="checkbox" name="admin_action[confirmed_bulk]" value="true" required />
          I confirm order-level revocation
        </label>
      </div>
      <div>
        <label class="block text-sm font-medium" for={"#{@id}-reason"}>Reason (required)</label>
        <textarea
          id={"#{@id}-reason"}
          name="admin_action[reason]"
          rows="3"
          required
          class="mt-1 w-full rounded border border-fc-border px-3 py-2 text-sm"
        ></textarea>
      </div>
      <div :if={@show_password}>
        <label class="block text-sm font-medium" for={"#{@id}-password"}>Admin password</label>
        <input
          id={"#{@id}-password"}
          type="password"
          name="admin_action[admin_password]"
          required
          class="mt-1 w-full rounded border border-fc-border px-3 py-2 text-sm"
        />
      </div>
      <input type="hidden" name="admin_action[idempotency_key]" value={Ecto.UUID.generate()} />
      <input
        :if={@ticket_issue_id}
        type="hidden"
        name="admin_action[ticket_issue_id]"
        value={@ticket_issue_id}
      />
      <button type="submit" class="rounded bg-red-700 px-4 py-2 text-sm font-medium text-white">
        {@submit_label}
      </button>
    </.form>
    """
  end

  defp issued_count_preview(0), do: "0"
  defp issued_count_preview(count) when is_integer(count), do: Integer.to_string(count)
  defp issued_count_preview(_), do: "0"
end
