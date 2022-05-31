use Mix.Config

config :ethereum_jsonrpc, EthereumJSONRPC.Tracer, env: "dev", disabled?: true

config :logger, :ethereum_jsonrpc,
  level: :error,
  path: Path.absname("logs/dev/ethereum_jsonrpc.log"),
  rotate: %{max_bytes: 2_097_152, keep: 1}
