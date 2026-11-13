defmodule VaultWeb.Layouts do
  use VaultWeb, :html
  embed_templates "layouts/*"

  attr :caption, :string, required: true

  def brand(assigns) do
    ~H"""
    <div class="brand">
      <span class="brand-mark" aria-hidden="true">✧</span>
      <div>
        <div class="brand-title">The Watchmaker’s Vault</div>
        <div class="eyebrow">{@caption}</div>
      </div>
    </div>
    """
  end

  def sign_out(assigns) do
    ~H"""
    <form method="post" action={~p"/logout"} class="sign-out">
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <button class="button quiet" type="submit">Sign out</button>
    </form>
    """
  end
end
