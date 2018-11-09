defmodule Transport.ReusableData do
  @moduledoc """
  The ReusableData bounded context.
  """

  import TransportWeb.Gettext
  alias Transport.ImportDataService
  alias Transport.ReusableData.Dataset
  require Logger

  @pool DBConnection.Poolboy
  @endpoint Application.get_env(:transport, :gtfs_validator_url) <> "/validate"
  @client HTTPoison
  @res HTTPoison.Response
  @err HTTPoison.Error
  @timeout 60_000

  @doc """
  Returns the list of reusable datasets filtered by a full text search.

  ## Examples

      iex> ReusableData.search_datasets("metro")
      ...> |> List.first
      ...> |> Map.get(:title)
      "Leningrad metro dataset"

      iex> ReusableData.search_datasets("hyperloop express")
      []

  """
  @spec search_datasets(String.t, Map.t) :: [%Dataset{}]
  def search_datasets(q, %{} = projection \\ %{}) when is_binary(q), do: list_datasets(%{"$text": %{"$search" => q}}, projection)

  @doc """
  Returns the list of reusable datasets containing no validation errors.

  ## Examples

      iex> ReusableData.list_datasets
      ...> |> List.first
      ...> |> Map.get(:title)
      "Leningrad metro dataset"

  """
  def list_datasets([projection: projection]), do: list_datasets(%{}, projection)
  @spec list_datasets(Map.t, Map.t) :: [%Dataset{}]
  def list_datasets(%{} = query \\ %{}, %{} = projection \\ %{}) do
    %{download_url: %{"$ne" => nil}}
    |> Map.merge(query)
    |> query_datasets(projection)
  end

  @doc """
  Return one dataset by id

  ## Examples

      iex> "leningrad-metro-dataset"
      ...> |> ReusableData.get_dataset
      ...> |> Map.get(:title)
      "Leningrad metro dataset"

      iex> ReusableData.get_dataset("")
      nil

  """
  @spec get_dataset(String.t) :: %Dataset{}
  def get_dataset(slug) do
    query = %{slug: slug}

    :mongo
    |> Mongo.find_one("datasets", query, pool: @pool)
    |> case do
      nil -> nil
      dataset -> Dataset.new(dataset)
    end
  end

  @doc """
  Creates a dataset.

  ## Examples

      iex> %{title: "Saintes"}
      ...> |> ReusableData.create_dataset
      ...> |> Map.get(:title)
      "Saintes"

      iex> %{"title" => "Rochefort"}
      ...> |> ReusableData.create_dataset
      ...> |> Map.get(:title)
      "Rochefort"

  """
  @spec create_dataset(map()) :: %Dataset{}
  def create_dataset(%{} = attrs) do
    {:ok, result} = Mongo.insert_one(:mongo, "datasets", attrs, pool: @pool)
    query         = %{"_id"  => result.inserted_id}

    :mongo
    |> Mongo.find_one("datasets", query, pool: @pool)
    |> Dataset.new
  end

  @doc """
  Builds a licence.

  ## Examples

      iex> %Dataset{licence: "fr-lo"}
      ...> |> ReusableData.localise_licence
      "Open Licence"

      iex> %Dataset{licence: "Libertarian"}
      ...> |> ReusableData.localise_licence
      "Not specified"

  """
  @spec localise_licence(%Dataset{}) :: String.t
  def localise_licence(%Dataset{licence: licence}) do
    case licence do
      "fr-lo" -> dgettext("reusable_data", "fr-lo")
      "odc-odbl" -> dgettext("reusable_data", "odc-odbl")
      "other-open" -> dgettext("reusable_data", "other-open")
      _ -> dgettext("reusable_data", "notspecified")
    end
  end

  @spec query_datasets(Map.t, Map.t) :: [%Dataset{}]
  def query_datasets(%{} = query, %{} = projection \\ %{}) do
    :mongo
    |> Mongo.find("datasets", query, pool: @pool, projection: projection)
    |> Enum.to_list()
    |> Enum.map(&Dataset.new(&1))
  end

  @spec import :: none()
  def import do
    :mongo
    |> Mongo.find("datasets", %{}, pool: @pool)
    |> Enum.map(&ImportDataService.call/1)
  end

  def validate_and_save(%Dataset{} = dataset) do
    Logger.info("Validating " <> dataset.download_url)
    dataset
    |> validate
    |> group_validations
    |> add_metadata
    |> save_validations
    |> case do
      {:ok, _} -> Logger.info("Ok!")
      {:error, error} -> Logger.warn("Error: " <> error)
      _ -> Logger.warn("Unknown error")
    end
  end

  def validate(%Dataset{download_url: url}) do
    with {:ok, %@res{status_code: 200, body: body}} <-
           @client.get(@endpoint <> "?url=#{url}", [], timeout: @timeout, recv_timeout: @timeout),
         {:ok, validations} <- Poison.decode(body) do
      {:ok, %{url: url, validations: validations}}
    else
      {:ok, %@res{body: body}} -> {:error, body}
      {:error, %@err{reason: error}} -> {:error, error}
      {:error, error} -> {:error, error}
      _ -> {:error, "Unknown error"}
    end
  end

  def save_validations({:ok, %{url: url, validations: validations}}) do
    Mongo.find_one_and_update(:mongo,
                              "datasets",
                              %{"download_url" => url},
                              %{"$set" => validations},
                              pool: @pool)
  end
  def save_validations({:error, error}), do: error
  def save_validations(error), do: {:error, error}

  def add_metadata({:ok, %{url: url, validations: validations}}) do
    {:ok,
    %{
      url: url,
      validations: Map.put(validations, "validation_date", DateTime.utc_now |> DateTime.to_string)
      }
    }
  end
  def add_metadata(error), do: error

  @doc """
  A validation is needed if the last update from the data is newer than the last validation.

  ## Examples

      iex> ReusableData.needs_validation(%Dataset{last_update: "2018-01-30", validation_date: "2018-01-01"})
      true

      iex> ReusableData.needs_validation(%Dataset{last_update: "2018-01-01", validation_date: "2018-01-30"})
      false

      iex> ReusableData.needs_validation(%Dataset{last_update: "2018-01-30"})
      true

  """
  def needs_validation(%Dataset{last_update: last_update, validation_date: validation_date}) do
    last_update > validation_date
  end
  def nedds_validation(_dataset), do: true

  @doc """
  A validation is needed if the last update from the data is newer than the last validation.

  ## Examples

      iex> ReusableData.group_validations(nil)
      nil

      iex> ReusableData.group_validations({:error, "moo"})
      {:error, "moo"}

      iex> v = %{"validations" => [%{"issue_type" => "Error"}]}
      iex> ReusableData.group_validations({:ok, %{url: "http", validations: v}})
      {:ok, %{url: "http", validations: %{"Error" => %{count: 1, issues: [%{"issue_type" => "Error"}]}}}}
  """
  def group_validations({:ok, %{url: url, validations: validations}}) do
    grouped_validations =
    validations
    |> Map.get("validations", [])
    |> Enum.group_by(fn validation -> validation["issue_type"] end)
    |> Map.new(fn {type, issues} -> {type, %{issues: issues, count: Enum.count issues}} end)

    {:ok, %{url: url, validations: grouped_validations}}
  end
  def group_validations(error), do: error
end
