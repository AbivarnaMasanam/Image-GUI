defmodule ImageProWeb.PageController do
  use ImageProWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
