defmodule TransportWeb.StatsController do
  alias Transport.ReusableData
  alias Transport.ReusableData.Dataset
  require Logger
  use TransportWeb, :controller

  def index(conn, _params) do
    aoms = Mongo.aggregate(
      :mongo,
      "aoms",
      [Dataset.aoms_lookup],
      pool: DBConnection.Poolboy
    )
    aoms_with_datasets = aoms |> Enum.filter(&(has_dataset?(&1) || is_bretagne?(&1)))

    regions = Mongo.aggregate(
      :mongo,
      "regions",
      [Dataset.regions_lookup],
      pool: DBConnection.Poolboy
    )
    regions_completed = regions |> Enum.filter(&is_completed?/1)

    population_totale =
      aoms
      |> Enum.reduce(0, &(get_population(&1) + &2))
      |> Kernel./(1000)
      |> Float.round(2)
    population_couverte =
      aoms_with_datasets
      |> Enum.reduce(0, &(get_population(&1) + &2))
      |> Kernel./(1000)
      |> Float.round(2)

    render(conn, "index.html",
     nb_datasets: Enum.count(ReusableData.list_datasets),
     nb_aoms: Enum.count(aoms),
     nb_aoms_with_data: aoms_with_datasets |> Enum.count,
     nb_regions: Enum.count(regions),
     nb_regions_completed: regions_completed |> Enum.count,
     population_totale: population_totale,
     population_couverte: population_couverte
    )
  end

  defp is_bretagne?(aom), do: fetch_property(aom, "liste_aom_Nouvelles régions") == {:ok, "Bretagne"}
  defp has_dataset?(aom), do: !Enum.empty?(Map.get(aom, "datasets", []))
  defp is_completed?(region), do: Map.get(Map.get(region, "properties", %{}), "completed", false)

  defp get_population(aom) do
    with {:ok, population} <- fetch_property(aom, "liste_aom_Population Totale 2014"),
         {int, _} <- Integer.parse(population)
    do
      int
    else
      _ ->
        Logger.info("Unable to parse population for #{aom}")
        0
    end
  end

  defp fetch_property(aom, property) do
    aom
    |> Map.get("properties", %{})
    |> Map.fetch(property)
  end
end
