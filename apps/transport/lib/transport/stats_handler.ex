defmodule Transport.StatsHandler do
  @moduledoc """
  Compute statistics on the datasets
  Also contains a function called periodically to store the stats in the DB
  """
  alias DB.{AOM, Dataset, Region, Repo, Resource, StatsHistory}
  alias Transport.CSVDocuments
  import Ecto.Query
  require Logger

  @doc """
  Compute and store all stats as a snapshot of the database
  """
  @spec store_stats() :: any()
  def store_stats do
    timestamp = DateTime.truncate(DateTime.utc_now(), :second)

    compute_stats() |> Enum.each(fn {k, v} -> store_stat_history(k, v, timestamp) end)
  end

  defp store_stat_history(:gtfs_rt_types = key, values, %DateTime{} = timestamp) do
    Enum.map(values, fn {feed_type, count} ->
      store_stat_history("#{key}::#{feed_type}", count, timestamp)
    end)
  end

  defp store_stat_history(key, value, %DateTime{} = timestamp) when is_number(value) do
    %StatsHistory{timestamp: timestamp, metric: to_string(key), value: value} |> Repo.insert!()
  end

  @doc """
  Compute all stats
  """
  @spec compute_stats() :: any()
  def compute_stats do
    aoms =
      Repo.all(
        from(a in AOM,
          select: %{
            population: a.population_totale,
            region_id: a.region_id,
            nb_datasets: fragment("SELECT count(*) FROM dataset where aom_id = ? and is_active", a.id),
            parent_dataset_id: a.parent_dataset_id
          }
        )
      )

    aoms_with_datasets = aoms |> Enum.filter(&(&1.nb_datasets > 0 || !is_nil(&1.parent_dataset_id)))

    regions = Repo.all(from(r in Region, where: r.nom != "National"))

    aoms_max_gtfs_severity = compute_aom_gtfs_max_severity()

    total_aom_with_gtfs_datasets =
      aoms_max_gtfs_severity
      |> Map.values()
      |> Enum.filter(fn error -> not is_nil(error) end)
      |> Enum.sum()

    %{
      nb_datasets: Repo.aggregate(Dataset.base_query(), :count, :id),
      nb_pt_datasets: Dataset.count_by_type("public-transit"),
      nb_aoms: Enum.count(aoms),
      nb_aoms_with_data: Enum.count(aoms_with_datasets),
      nb_regions: Enum.count(regions),
      nb_regions_completed: regions |> Enum.count(fn r -> r.is_completed end),
      population_totale: get_population(aoms),
      population_couverte: get_population(aoms_with_datasets),
      ratio_aom_with_at_most_warnings:
        ratio_aom_with_at_most_warnings(aoms_max_gtfs_severity, total_aom_with_gtfs_datasets),
      ratio_aom_good_quality: ratio_aom_good_quality(aoms_max_gtfs_severity, total_aom_with_gtfs_datasets),
      aom_with_errors: Map.get(aoms_max_gtfs_severity, "Error", 0),
      aom_with_fatal: Map.get(aoms_max_gtfs_severity, "Fatal", 0),
      nb_official_public_transit_realtime: nb_official_public_transit_realtime(),
      nb_unofficial_public_transit_realtime: nb_unofficial_public_transit_realtime(),
      nb_reusers: nb_reusers(),
      nb_reuses: nb_reuses(),
      nb_dataset_types: nb_dataset_types(),
      nb_gtfs: count_dataset_with_format("GTFS"),
      nb_netex: count_dataset_with_format("NeTEx"),
      nb_bss_datasets: count_dataset_with_format("gbfs"),
      nb_bikes_scooter_datasets: nb_bikes_scooters(),
      nb_gtfs_rt: count_dataset_with_format("gtfs-rt"),
      gtfs_rt_types: count_feed_types_gtfs_rt(),
      nb_siri: count_dataset_with_format("SIRI"),
      nb_siri_lite: count_dataset_with_format("SIRI Lite")
    }
  end

  @doc """
  Count the number of gtfs-rt entities seen in the last 7 days on our resources
  Output example: %{"service_alerts" => 12, "trip_updates" => 63, "vehicle_positions" => 42}
  """
  @spec count_feed_types_gtfs_rt :: map()
  def count_feed_types_gtfs_rt do
    features =
      DB.ResourceMetadata.base_query()
      |> distinct(true)
      |> join(:inner, [metadata: m], r in DB.Resource, on: r.id == m.resource_id, as: :resource)
      |> where(
        [metadata: m, resource: r],
        r.format == "gtfs-rt" and m.inserted_at > ^Transport.Jobs.GTFSRTEntitiesJob.datetime_limit()
      )
      |> select([metadata: m], %{resource_id: m.resource_id, feature: fragment("unnest(?)", m.features)})

    q = from(f in subquery(features))

    q
    |> group_by([f], f.feature)
    |> select([f], {f.feature, count(f.feature)})
    |> DB.Repo.all()
    |> Enum.into(%{})
  end

  defp get_population(datasets) do
    datasets
    |> Enum.reduce(0, &(&1.population + &2))
    |> Kernel./(1_000_000)
    |> Kernel.round()
  end

  defp nb_official_public_transit_realtime do
    rt_datasets =
      from(d in Dataset,
        where: d.has_realtime and d.is_active and d.type == "public-transit"
      )

    Repo.aggregate(rt_datasets, :count, :id)
  end

  @spec nb_bikes_scooters() :: integer
  defp nb_bikes_scooters do
    bikes_datasets =
      from(d in Dataset,
        where: d.type == "bike-scooter-sharing" and d.is_active
      )

    Repo.aggregate(bikes_datasets, :count, :id)
  end

  defp nb_unofficial_public_transit_realtime do
    Enum.count(CSVDocuments.real_time_providers())
  end

  defp nb_dataset_types do
    Dataset
    |> select([d], count(d.type, :distinct))
    |> Repo.one()
  end

  defp nb_reusers do
    Enum.count(CSVDocuments.reusers())
  end

  defp nb_reuses do
    Repo.aggregate(Dataset, :sum, :nb_reuses) || 0
  end

  def count_dataset_with_format(format) do
    Resource
    |> join(:inner, [r], d in Dataset, on: r.dataset_id == d.id)
    |> where([_r, d], d.is_active)
    |> select([r], count(r.dataset_id, :distinct))
    |> where([r], r.format == ^format)
    |> Repo.one()
  end

  @spec compute_aom_gtfs_max_severity() :: %{binary() => integer()}
  def compute_aom_gtfs_max_severity do
    # consolidate the maximum error for the current datasets of each AOMs
    # return, for each error, the number of AOM with this maximum error
    dt = Date.utc_today()

    validation_infos =
      DB.Dataset.base_query()
      |> DB.Dataset.join_from_dataset_to_metadata(Transport.Validators.GTFSTransport.validator_name())
      |> select([resource: r, multi_validation: mv, metadata: m], %{
        max_error:
          fragment("""
          CASE max_error::text
          WHEN 'Fatal' THEN 4
          WHEN 'Error' THEN 3
          WHEN 'Warning' THEN 2
          WHEN 'Information' THEN 1
          ELSE 0
          END
          """),
        resource_id: r.id,
        end_date: fragment("TO_DATE(?->>'end_date', 'YYYY-MM-DD')", m.metadata)
      })

    AOM
    |> join(:left, [aom], dataset in Dataset, on: dataset.id == aom.parent_dataset_id or dataset.aom_id == aom.id)
    |> join(:left, [_, dataset], _r in assoc(dataset, :resources))
    |> join(:left, [_, _, r], v in subquery(validation_infos), on: v.resource_id == r.id)
    |> where([_a, _d, r, _v], r.format == "GTFS")
    |> where([_a, _d, _r, v], v.end_date >= ^dt)
    |> group_by([a, _d, _r, v], a.id)
    |> select([a, d, r, v], %{
      aom: a.id,
      max_error: max(v.max_error)
    })
    |> Repo.all()
    |> List.foldl(%{}, fn %{max_error: max_error}, acc ->
      max_error =
        case max_error do
          4 -> "Fatal"
          3 -> "Error"
          2 -> "Warning"
          1 -> "Information"
          0 -> "NoError"
          _ -> nil
        end

      Map.update(acc, max_error, 1, fn v -> v + 1 end)
    end)
  end

  @spec ratio_aom_with_at_most_warnings(%{binary() => integer()}, integer()) :: integer()
  defp ratio_aom_with_at_most_warnings(_aom_max_severity, 0) do
    0
  end

  defp ratio_aom_with_at_most_warnings(aom_max_severity, nb_aom_with_data) do
    sum =
      Map.get(aom_max_severity, "Warning", 0) +
        Map.get(aom_max_severity, "Information", 0) +
        Map.get(aom_max_severity, "Irrelevant", 0) +
        Map.get(aom_max_severity, "NoError", 0)

    sum / nb_aom_with_data
  end

  @spec ratio_aom_good_quality(%{binary() => integer()}, integer()) :: integer()
  defp ratio_aom_good_quality(_aom_max_severity, 0) do
    0
  end

  defp ratio_aom_good_quality(aom_max_severity, nb_aom_with_data) do
    sum =
      Map.get(aom_max_severity, "Information", 0) +
        Map.get(aom_max_severity, "Irrelevant", 0) +
        Map.get(aom_max_severity, "NoError", 0)

    sum / nb_aom_with_data
  end
end
