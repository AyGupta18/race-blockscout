defmodule Explorer.Chain.CeloContractEvent do
  @moduledoc """
    Representing an event emitted from a Celo core contract.
  """
  require Logger

  use Explorer.Schema
  import Ecto.Query

  alias Explorer.Celo.ContractEvents.{Common, EventMap}
  alias Explorer.Chain.{Hash, Log}
  alias Explorer.Chain.Hash.Address
  alias Explorer.Repo

  @type t :: %__MODULE__{
          name: String.t(),
          topic: String.t(),
          log_index: non_neg_integer(),
          block_number: non_neg_integer(),
          contract_address_hash: Hash.Address.t(),
          transaction_hash: Hash.Full.t(),
          params: map()
        }

  @attrs ~w( name contract_address_hash transaction_hash log_index params topic block_number)a
  @required ~w( name contract_address_hash log_index topic block_number)a

  @primary_key false
  schema "celo_contract_events" do
    field(:block_number, :integer, primary_key: true)
    field(:log_index, :integer, primary_key: true)
    field(:name, :string)
    field(:topic, :string)
    field(:params, :map)
    field(:contract_address_hash, Address)
    field(:transaction_hash, Hash.Full)

    timestamps(null: false, type: :utc_datetime_usec)
  end

  def changeset(%__MODULE__{} = item, attrs) do
    item
    |> cast(attrs, @attrs)
    |> validate_required(@required)
  end

  @doc "returns ids of entries in log table that contain events not yet included in CeloContractEvents table"
  def fetch_unprocessed_log_ids_query(topics) when is_list(topics) do
    from(l in "logs",
      select: {l.block_number, l.index},
      left_join: cce in __MODULE__,
      on: {cce.block_number, cce.log_index} == {l.block_number, l.index},
      where: l.first_topic in ^topics and is_nil(cce.block_number),
      order_by: [asc: l.block_number, asc: l.index]
    )
  end

  @throttle_ms 100
  @batch_size 1000
  @doc "Insert events as yet unprocessed from Log table into CeloContractEvents"
  def insert_unprocessed_events(events, batch_size \\ @batch_size) do
    # fetch ids of missing events
    ids =
      events
      |> Enum.map(& &1.topic)
      |> fetch_unprocessed_log_ids_query()
      |> Repo.all()

    # batch convert and insert new rows
    ids
    |> Enum.chunk_every(batch_size)
    |> Enum.map(fn batch ->
      to_insert =
        batch
        |> fetch_params()
        |> Repo.all()
        |> EventMap.rpc_to_event_params()
        |> set_timestamps()

      result = Repo.insert_all(__MODULE__, to_insert, returning: [:block_number, :log_index])

      Process.sleep(@throttle_ms)
      result
    end)
  end

  def fetch_params(ids) do
    # convert list of {block_number, index} tuples to two lists of [block_number] and [index] because ecto can't handle
    # direct tuple comparisons with a WHERE IN clause
    {blocks, indices} =
      ids
      |> Enum.reduce([[], []], fn {block, index}, [blocks, indices] ->
        [[block | blocks], [index | indices]]
      end)
      |> then(fn [blocks, indices] -> {Enum.reverse(blocks), Enum.reverse(indices)} end)

    from(
      l in Log,
      join: v in fragment("SELECT * FROM unnest(?::bytea[], ?::int[]) AS v(block_number,index)", ^blocks, ^indices),
      on: v.block_number == l.block_number and v.index == l.index
    )
  end

  defp set_timestamps(events) do
    # Repo.insert_all does not handle timestamps, set explicitly here
    timestamp = Timex.now()

    Enum.map(events, fn e ->
      e
      |> Map.put(:inserted_at, timestamp)
      |> Map.put(:updated_at, timestamp)
    end)
  end

  def query_by_voter_param(query, voter_address_hash) do
    voter_address_for_pg = Common.fa(voter_address_hash)

    from(c in query,
      where: fragment("? ->> ? = ?", c.params, "account", ^voter_address_for_pg)
    )
  end

  def query_by_group_param(query, group_address_hash) do
    group_address_for_pg = Common.fa(group_address_hash)

    from(c in query,
      where: fragment("? ->> ? = ?", c.params, "group", ^group_address_for_pg)
    )
  end

  def query_by_validator_param(query, validator_address_hash) do
    validator_address_for_pg = Common.fa(validator_address_hash)

    from(c in query,
      where: fragment("? ->> ? = ?", c.params, "validator", ^validator_address_for_pg)
    )
  end
end
