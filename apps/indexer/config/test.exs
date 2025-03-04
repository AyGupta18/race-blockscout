use Mix.Config

config :indexer, Indexer.Tracer, disabled?: false

config :indexer, Indexer.Fetcher.CeloValidatorHistory.Supervisor, disabled?: true

config :indexer, Indexer.Block.Fetcher, enable_gold_token: true

config :indexer,
  block_transformer: Indexer.Transform.Blocks.Base

config :logger, :indexer,
  level: :warn,
  path: Path.absname("logs/test/indexer.log")

config :logger, :indexer_token_balances,
  level: :debug,
  path: Path.absname("logs/test/indexer/token_balances/error.log"),
  metadata_filter: [fetcher: :token_balances]

config :logger, :failed_contract_creations,
  level: :debug,
  path: Path.absname("logs/test/indexer/failed_contract_creations.log"),
  metadata_filter: [fetcher: :failed_created_addresses]

config :logger, :addresses_without_code,
  level: :debug,
  path: Path.absname("logs/test/indexer/addresses_without_code.log"),
  metadata_filter: [fetcher: :addresses_without_code]

variant =
  if is_nil(System.get_env("ETHEREUM_JSONRPC_VARIANT")) do
    "parity"
  else
    System.get_env("ETHEREUM_JSONRPC_VARIANT")
    |> String.split(".")
    |> List.last()
    |> String.downcase()
  end

# Import variant specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "test/#{variant}.exs"
