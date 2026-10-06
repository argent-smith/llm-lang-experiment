# frozen_string_literal: true

# Всё вместе: сервер и клиент. Точки входа грузят только своё:
# bin/syncbox-server — "syncbox/server_cli", bin/syncbox — "syncbox/client".
require_relative "syncbox/version"
require_relative "syncbox/config"
require_relative "syncbox/store"
require_relative "syncbox/app"
require_relative "syncbox/server"
require_relative "syncbox/server_cli"
require_relative "syncbox/client"
