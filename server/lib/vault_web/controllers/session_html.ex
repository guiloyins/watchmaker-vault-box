defmodule VaultWeb.SessionHTML do
  use VaultWeb, :html
  import VaultWeb.Layouts, only: [brand: 1]
  embed_templates "session_html/*"
end
