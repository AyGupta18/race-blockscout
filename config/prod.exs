use Mix.Config

# Do not print debug messages in production

config :logger, :console, level: :info

config :logger, :ecto,
  level: :error,
  path: Path.absname("logs/prod/ecto.log"),
  rotate: %{max_bytes: 52_428_800, keep: 19}

config :logger, :error,
  path: Path.absname("logs/prod/error.log"),
  rotate: %{max_bytes: 52_428_800, keep: 19}
