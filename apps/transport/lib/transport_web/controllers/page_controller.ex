defmodule TransportWeb.PageController do
  use TransportWeb, :controller
  alias DB.{AOM, Dataset, Partner, Region, Repo}
  alias Transport.CSVDocuments
  import Ecto.Query
  import TransportWeb.DatasetView, only: [icon_type_path: 1]
  import TransportWeb.Router.Helpers

  def index(conn, _params) do
    conn
    |> assign(:mailchimp_newsletter_url, Application.get_env(:transport, :mailchimp_newsletter_url))
    |> merge_assigns(home_index_stats())
    |> assign(:tiles, home_tiles(conn))
    |> put_breaking_news(DB.BreakingNews.get_breaking_news())
    |> render("index.html")
  end

  defp home_index_stats do
    Transport.Cache.API.fetch("home-index-stats", fn -> compute_home_index_stats() end)
  end

  defp put_breaking_news(conn, %{level: level, msg: msg}), do: conn |> put_flash(String.to_atom(level), msg)
  defp put_breaking_news(conn, %{}), do: conn

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(ErrorView)
    |> render("404.html")
  end

  defp compute_home_index_stats do
    [
      count_by_type: Dataset.count_by_type(),
      count_train: Dataset.count_by_mode("rail"),
      count_boat: Dataset.count_by_mode("ferry"),
      count_coach: Dataset.count_coach(),
      count_aoms_with_dataset: count_aoms_with_dataset(),
      count_regions_completed: count_regions_completed(),
      count_public_transport_has_realtime: Dataset.count_public_transport_has_realtime(),
      percent_population: percent_population(),
      reusers: CSVDocuments.reusers(),
      facilitators: CSVDocuments.facilitators()
    ]
  end

  def login(conn, params) do
    conn
    |> put_session(:redirect_path, Map.get(params, "redirect_path", "/"))
    |> render("login.html")
  end

  def partners(conn) do
    partners =
      Partner
      |> Repo.all()
      |> Task.async_stream(fn partner -> Map.put(partner, :description, Partner.description(partner)) end)
      |> Task.async_stream(fn {:ok, partner} -> Map.put(partner, :count_reuses, Partner.count_reuses(partner)) end)
      |> Stream.map(fn {:ok, partner} -> partner end)
      |> Enum.to_list()

    conn
    |> assign(:partners, partners)
    |> assign(:page, "partners.html")
    |> render("single_page.html")
  end

  defp single_page(conn, %{"page" => page}) do
    conn
    |> assign(:page, page <> ".html")
    |> render("single_page.html")
  end

  def real_time(conn, _params) do
    conn
    |> assign(:providers, CSVDocuments.real_time_providers())
    |> single_page(%{"page" => "real_time"})
  end

  def conditions(conn, _params) do
    single_page(conn, %{"page" => "conditions"})
  end

  def infos_producteurs(conn, _params) do
    conn
    |> assign(:mailchimp_newsletter_url, Application.get_env(:transport, :mailchimp_newsletter_url))
    |> render("infos_producteurs.html")
  end

  def security_txt(conn, _params) do
    expires = DateTime.utc_now() |> DateTime.add(1 * 24 * 3600 * 7, :second) |> DateTime.to_iso8601()

    content = """
    Contact: mailto:#{Application.fetch_env!(:transport, :security_email)}
    Preferred-Languages: fr, en
    Expires: #{expires}
    """

    conn |> text(content)
  end

  @doc """
    Retrieve the user datasets + corresponding org datasets.

    Data Gouv is queried, and we support a degraded mode with an error reporting in case of connection issue.
  """
  def espace_producteur(conn, _params) do
    {datasets, errors} =
      [
        Dataset.user_datasets(conn),
        Dataset.user_org_datasets(conn)
      ]
      |> Enum.split_with(&(elem(&1, 0) == :ok))

    datasets =
      datasets
      |> Enum.map(&elem(&1, 1))
      |> List.flatten()

    errors
    |> Enum.each(&Sentry.capture_exception(&1))

    # NOTE: this could be refactored in more functional style, but that will be good enough for today
    conn =
      if length(errors) != 0 do
        conn |> put_flash(:error, dgettext("alert", "Unable to get all your resources for the moment"))
      else
        conn
      end

    conn
    |> assign(:datasets, datasets)
    |> render("espace_producteur.html")
  end

  defp aoms_with_dataset do
    from(a in AOM,
      join: d in Dataset,
      on: a.id == d.aom_id or not is_nil(a.parent_dataset_id),
      distinct: a.id
    )
  end

  defp count_aoms_with_dataset, do: Repo.aggregate(aoms_with_dataset(), :count, :id)

  defp population_with_dataset, do: Repo.aggregate(aoms_with_dataset(), :sum, :population_totale_2014)

  defp population_totale, do: Repo.aggregate(AOM, :sum, :population_totale_2014)

  defp percent_population, do: percent(population_with_dataset(), population_totale())

  defp percent(_a, 0), do: 0
  defp percent(_a, nil), do: 0
  defp percent(a, b), do: Float.round(a / b * 100, 1)

  defp count_regions_completed do
    Region
    |> where([r], r.is_completed == true)
    |> Repo.aggregate(:count, :id)
  end

  defmodule Tile do
    @enforce_keys [:link, :icon, :title, :count]
    defstruct [:link, :icon, :title, :count]
  end

  defp home_tiles(conn) do
    counts = home_index_stats()

    [
      %Tile{
        link: dataset_path(conn, :index, type: "public-transit"),
        icon: icon_type_path("public-transit"),
        title: dgettext("page-index", "Public transport - static schedules"),
        count: Keyword.fetch!(counts, :count_by_type)["public-transit"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "public-transit", filter: "has_realtime"),
        icon: icon_type_path("real-time-public-transit"),
        title: dgettext("page-index", "Public transport - realtime trafic"),
        count: Keyword.fetch!(counts, :count_public_transport_has_realtime)
      },
      %Tile{
        # 14 is the region « national » We defined coaches as buses not bound to a region or AOM
        link: dataset_path(conn, :by_region, 14, "modes[]": "bus"),
        icon: icon_type_path("long-distance-coach"),
        title: dgettext("page-index", "Long distance coach"),
        count: Keyword.fetch!(counts, :count_coach)
      },
      %Tile{
        link: dataset_path(conn, :index, "modes[]": "rail"),
        icon: icon_type_path("train"),
        title: dgettext("page-index", "Rail transport"),
        count: Keyword.fetch!(counts, :count_train)
      },
      %Tile{
        link: dataset_path(conn, :index, "modes[]": "ferry"),
        icon: icon_type_path("boat"),
        title: dgettext("page-index", "Sea and river transport"),
        count: Keyword.fetch!(counts, :count_boat)
      },
      %Tile{
        link: dataset_path(conn, :index, type: "air-transport"),
        icon: icon_type_path("air-transport"),
        title: dgettext("page-index", "Air transport"),
        count: Keyword.fetch!(counts, :count_by_type)["air-transport"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "bike-scooter-sharing"),
        icon: icon_type_path("bike-scooter-sharing"),
        title: dgettext("page-index", "Bike and scooter sharing"),
        count: Keyword.fetch!(counts, :count_by_type)["bike-scooter-sharing"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "bike-way"),
        icon: icon_type_path("bike-way"),
        title: dgettext("page-index", "Bike networks"),
        count: Keyword.fetch!(counts, :count_by_type)["bike-way"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "bike-parking"),
        icon: icon_type_path("bike-parking"),
        title: dgettext("page-index", "Bike parking"),
        count: Keyword.fetch!(counts, :count_by_type)["bike-parking"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "road-network"),
        icon: icon_type_path("road-network"),
        title: dgettext("page-index", "Road networks"),
        count: Keyword.fetch!(counts, :count_by_type)["road-network"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "low-emission-zones"),
        icon: icon_type_path("low-emission-zones"),
        title: dgettext("page-index", "Low emission zones"),
        count: Keyword.fetch!(counts, :count_by_type)["low-emission-zones"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "carpooling-areas"),
        icon: icon_type_path("carpooling-areas"),
        title: dgettext("page-index", "Carpooling areas"),
        count: Keyword.fetch!(counts, :count_by_type)["carpooling-areas"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "charging-stations"),
        icon: icon_type_path("charging-stations"),
        title: dgettext("page-index", "Charging & refuelling stations"),
        count: Keyword.fetch!(counts, :count_by_type)["charging-stations"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "private-parking"),
        icon: icon_type_path("private-parking"),
        title: dgettext("page-index", "Private parking"),
        count: Keyword.fetch!(counts, :count_by_type)["private-parking"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "addresses"),
        icon: icon_type_path("addresses"),
        title: dgettext("page-index", "Addresses"),
        count: Keyword.fetch!(counts, :count_by_type)["addresses"]
      },
      %Tile{
        link: dataset_path(conn, :index, type: "informations"),
        icon: icon_type_path("informations"),
        title: dgettext("page-index", "Other informations"),
        count: Keyword.fetch!(counts, :count_by_type)["informations"]
      }
    ]
  end
end
