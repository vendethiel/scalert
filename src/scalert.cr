require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

GAMES = %w(sc2 scbw csgo hots ssb ow).map(&.upcase)

CONFIG_FILE = "config.json"
config = ScConfig.from_json(File.read(CONFIG_FILE))
config.filename = CONFIG_FILE

client = Discord::Client.new(token: ENV["SCALERT_TOKEN"], client_id: ENV["SCALERT_CLIENTID"].to_u64)
print("Bot #{ENV["SCALERT_TOKEN"]} client_id #{ENV["SCALERT_CLIENTID"].to_u64}")
api = ScAPI.new(ENV["SCALERT_API_URL"])
scbot = ScBot.new(client, config, api)
scalert = ScAlerter.new(scbot)
scalert.run
client.run
