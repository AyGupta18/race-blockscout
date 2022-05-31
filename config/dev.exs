use Mix.Config

# DO NOT make it `:debug` or all Ecto logs will be shown for indexer
config :logger, :console, level: :info

config :logger, :ecto,
  level: :error,
  path: Path.absname("logs/dev/ecto.log"),
  rotate: %{max_bytes: 2_097_152, keep: 1}

config :logger, :error, path: Path.absname("logs/dev/error.log")
