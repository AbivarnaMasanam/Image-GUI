defmodule ImagePro.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ImageProWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:image_pro, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: ImagePro.PubSub},
      # Start a worker by calling: ImagePro.Worker.start_link(arg)
      # {ImagePro.Worker, arg},
      # Start to serve requests, typically the last entry
      ImageProWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: ImagePro.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ImageProWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
