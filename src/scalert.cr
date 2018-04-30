require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

GAMES = %w(sc2 scbw csgo hots ssb ow).map(&.upcase)

ALIAS_LIST_FILE = "aliases.txt"
CONFIG_FILE = "config.json"

config = ScConfig.from_json(File.read(CONFIG_FILE))
config.filename = CONFIG_FILE

client = Discord::Client.new(token: "Bot #{ENV["SCALERT_TOKEN"]}", client_id: ENV["SCALERT_CLIENTID"].to_u64)
streams = Alias.new(ALIAS_LIST_FILE)
api = ScAPI.new(streams, ENV["SCALERT_API_URL"])
scbot = ScBot.new(client, config, streams, api)
scalert = ScAlerter.new(scbot)
scalert.run
client.run
