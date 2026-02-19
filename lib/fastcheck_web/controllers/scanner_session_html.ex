defmodule FastCheckWeb.ScannerSessionHTML do
  @moduledoc """
  HEEx templates for scanner-only session pages.
  """

  use FastCheckWeb, :html

  embed_templates "scanner_session_html/*"
end
