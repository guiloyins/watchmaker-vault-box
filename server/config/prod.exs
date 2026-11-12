import Config

# M1 startup validates required operational paths and protected credentials.
config :vault, data_dir: nil, database: nil, simulator_database: nil
config :logger, level: :info
