use Mix.Config

config :indexer, Indexer.Tracer, env: "dev", disabled?: true

config :logger, :indexer,
  level: :error,
  path: Path.absname("logs/dev/indexer.log"),
  rotate: %{max_bytes: 2_097_152, keep: 1}

config :logger, :indexer_token_balances,
  level: :error,
  path: Path.absname("logs/dev/indexer/token_balances/error.log"),
  metadata_filter: [fetcher: :token_balances],
  rotate: %{max_bytes: 2_097_152, keep: 1}

config :logger, :failed_contract_creations,
  level: :error,
  path: Path.absname("logs/dev/indexer/failed_contract_creations.log"),
  metadata_filter: [fetcher: :failed_created_addresses]

config :logger, :addresses_without_code,
  level: :error,
  path: Path.absname("logs/dev/indexer/addresses_without_code.log"),
  metadata_filter: [fetcher: :addresses_without_code]

config :logger, :pending_transactions_to_refetch,
  level: :error,
  path: Path.absname("logs/dev/indexer/pending_transactions_to_refetch.log"),
  metadata_filter: [fetcher: :pending_transactions_to_refetch]

variant =
  if is_nil(System.get_env("ETHEREUM_JSONRPC_VARIANT")) do
    "ganache"
  else
    System.get_env("ETHEREUM_JSONRPC_VARIANT")
    |> String.split(".")
    |> List.last()
    |> String.downcase()
  end

# Import variant specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "dev/#{variant}.exs"
