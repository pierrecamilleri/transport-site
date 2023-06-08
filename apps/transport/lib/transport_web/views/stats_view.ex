defmodule TransportWeb.StatsView do
  use TransportWeb, :view
  import Phoenix.Component, only: [live_render: 2]

  def friendly_gtfs_type(type) when is_binary(type) do
    Map.fetch!(
      %{
        "trip_updates" => dgettext("stats", "Trip updates"),
        "vehicle_positions" => dgettext("stats", "Vehicle positions"),
        "service_alerts" => dgettext("stats", "Service alerts")
      },
      type
    )
  end
end
