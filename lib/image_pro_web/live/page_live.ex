defmodule ImageProWeb.PageLive do
  use ImageProWeb, :live_view

  embed_templates("page_html/*")

  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  def render(assigns) do
    ImageProWeb.PageHTML.home(assigns)
  end
end
