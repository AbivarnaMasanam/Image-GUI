defmodule ImageProWeb.AbiController do
  use ImageProWeb, :controller

  def abi(conn, _params) do
    render(conn, :abi)
  end
end
