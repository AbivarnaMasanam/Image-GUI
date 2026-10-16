defmodule ImageProWeb.AbiHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use ImageProWeb, :html

  embed_templates("abi_html/*")
end
