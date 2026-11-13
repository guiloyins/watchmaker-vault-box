defmodule VaultWeb.AuthTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn, only: [get_resp_header: 2]

  @endpoint VaultWeb.Endpoint

  test "host key POST is bounded, CSRF-protected, renewed and absent from the response" do
    {:ok, id} = Vault.Games.active_id()
    key = credential("host.key")
    conn = get(build_conn(), "/login")
    token = csrf_token(html_response(conn, 200))
    refute html_response(conn, 200) =~ key

    signed_in =
      conn
      |> recycle()
      |> post("/login", %{"access_token" => key, "_csrf_token" => token})

    assert redirected_to(signed_in) == "/games/#{id}/host"
    assert [cookie] = get_resp_header(signed_in, "set-cookie")
    assert cookie =~ "HttpOnly"
    assert cookie =~ "SameSite=Lax"
    refute cookie =~ key
    refute signed_in.resp_body =~ key

    missing_csrf = Plug.Conn.put_private(build_conn(), :plug_skip_csrf_protection, false)
    assert_error_sent 403, fn -> post(missing_csrf, "/login", %{"access_token" => key}) end
  end

  test "a scoped join cannot view the other role or host page" do
    {:ok, id} = Vault.Games.active_id()
    conn = get(build_conn(), "/join")

    joined =
      conn
      |> recycle()
      |> post("/join", %{
        "access_token" => credential("player-a.key"),
        "_csrf_token" => csrf_token(html_response(conn, 200))
      })

    assert redirected_to(joined) == "/games/#{id}/play/a"

    page = joined |> recycle() |> get("/games/#{id}/play/a") |> html_response(200)
    assert page =~ "Terminal A"
    refute page =~ "Terminal B"
    refute page =~ "Host console"

    assert joined |> recycle() |> get("/games/#{id}/play/b") |> response(403) == "Access denied"
    assert joined |> recycle() |> get("/games/#{id}/host") |> response(403) == "Access denied"
    assert joined |> recycle() |> get("/games/#{id}/play/c") |> response(403) == "Access denied"
  end

  defp credential(filename) do
    :vault
    |> Application.fetch_env!(:data_dir)
    |> Path.join(filename)
    |> File.read!()
    |> String.trim()
  end

  defp csrf_token(html) do
    [_, token] = Regex.run(~r/name="_csrf_token" value="([^"]+)"/, html)
    token
  end
end
