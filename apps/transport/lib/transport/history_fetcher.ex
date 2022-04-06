defmodule Transport.History.Fetcher do
  @moduledoc """
  Boundary for all retrieval resources' history, with an indirection to
  the default implementation. This allows easy stubbing of history system
  for tests which have no interest in it (that is: most of the tests).
  """
  @callback history_resources(DB.Dataset.t()) :: [map()]

  def impl, do: Application.get_env(:transport, :history_impl)

  def history_resources(%DB.Dataset{} = dataset), do: impl().history_resources(dataset)
end

defmodule Transport.History.Fetcher.Database do
  @moduledoc """
  Fetch %DB.ResourceHistory models from the database
  for a %DB.Dataset
  """
  @behaviour Transport.History.Fetcher
  import Ecto.Query
  alias DB.{Dataset, Repo, Resource, ResourceHistory}

  @impl true
  def history_resources(%Dataset{id: dataset_id}) do
    ResourceHistory
    |> join(:left, [rh], r in Resource, on: rh.datagouv_id == r.datagouv_id and r.dataset_id == ^dataset_id)
    |> where([_rh, r], not is_nil(r.id) or fragment("cast(payload->>'dataset_id' as bigint) = ?", ^dataset_id))
    |> order_by([rh, _r], desc: rh.inserted_at)
    |> select([rh, _r], rh)
    |> Repo.all()
  end
end

defmodule Transport.History.Fetcher.Null do
  @moduledoc """
  A default implementation returning an empty history,
  useful as a default implementation for dev.
  """
  @behaviour Transport.History.Fetcher

  @impl true
  def history_resources(%DB.Dataset{}), do: []
end
