require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

API_BASE_URL = "http://elgrandeapidelteamliquid.herokuapp.com"
GAMES = %w(sc2 scbw csgo hots ssb ow).map(&.upcase)

class Alias
  def initialize(@filename : String)
    @aliases = {} of String => String
    puts("loading alias list from #{filename}")
    begin
      File.each_line(filename, chomp: true) do |line|
        parts = line.split('=', 2)
        @aliases[parts[0]] = parts[1]
      end
    rescue ex
      puts("Unable to open file:\n#{ex.inspect_with_backtrace}")
    end
  end

  delegate :fetch, :[], :has_key?, to: @aliases
  def []=(key, value)
    @aliases[key] = value
    save!
  end

  private def save!
    File.write(@filename, self.to_s)
  end

  def to_s
    @aliases.map { |e| "#{e[0]}=#{e[1]}" }.join("\n")
  end
end

class ScEvent
  getter id : Int64
  getter name : String
  getter game : String
  getter timer : String?
  getter url : String?

  def initialize(@id, @name, @game, event, name_url)
    if event["timer"]?
        @timer = event["timer"].as_s
      @desc = @timer
    elsif name_url # by-name stream URL
      @url = name_url
    elsif event["url"]?
      @url = event["url"].as_s
    end
  end

  def to_s(include_game = false)
    " * #{name}#{include_game ? " (#{@game})" : ""} #{desc}"
  end

  def desc
    if @timer
      "- #{@timer}"
    elsif @url
      "- <#{@url}>"
    else
      ""
    end
  end

  def self.json_name(event)
    event["name"].as_s
  end
end

# Converts between a Hash(String, Array(String)) and Hash(UInt64, Array(String))
# XXX that Array(String) probably wants to be an Array(Game enum)
module GameHashConverter
  def self.to_json(value : Hash(UInt64, Array(String)), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k.to_s do
          json.array do
            v.each {|game| json.string(game)}
          end
        end
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of UInt64 => Array(String)
    json.read_object do |key|
      games = [] of String
      json.read_array do
        games << json.read_string
      end
      hash[key.to_u64] = games
    end
    hash
  end
end

class ScConfig
  setter filename : String | Nil
  def save!
    puts("Saving config to #{CONFIG_FILE}")

    filename = @filename
    Process.exit "No config file" unless filename # means someome changed the config loading code
    File.write(filename, to_pretty_json)
  end

  JSON.mapping(
    max_events: Int32,
    announcements: {type: Hash(UInt64, Array(String)), converter: GameHashConverter},
    events_command: {type: Hash(UInt64, Array(String)), converter: GameHashConverter},
    lp_event_channels: {type: Hash(UInt64, Array(String)), converter: GameHashConverter},
    admins: Array(UInt64)
  )
end

class ScAlert
  def initialize(@client : Discord::Client, @config : ScConfig, alias_filename : String)
    @aliases = Alias.new(alias_filename)
    @timers = {} of String => Time
  end

  delegate max_events, announcements, events_command, lp_event_channels, admins, to: @config

  def format_events(events, show_game)
    events.map{|e| e.to_s(show_game)}.join("\n")
  end

  def with_poller(current_events, category, &block)
    puts("[#{category}] start events: #{current_events}")
    loop do
      begin
        events = run_category(category) || [] of ScEvent
        puts("[#{category}] current events: #{current_events}")
        puts("[#{category}] fetched events: #{events}")

        new_events = events.reject{|e| current_events.includes?(e.id) }
        puts("[#{category}] new events: #{new_events}")
        if new_events.size > 0
          current_events += (yield new_events).map &.id
        end
      rescue ex
        puts "Rescued poller exception\n#{ex.inspect_with_backtrace}"
      end
      sleep 5.minutes
    end
  end

  def poll_live_events
    current_events = run_category("levents").try{|c| c.map &.id} || [] of Int64
    with_poller(current_events, "levents") do |events|
      # for each channel to announce on...
      announcements.each do |channel_id, games|
        events_to_announce = events.select{|e| games.includes?(e.game)}
        next unless events_to_announce.size > 0
        show_game = games.size > 1 # show the game if there could be confusion
        safe_create_message(channel_id, " ** LIVE **\n" + format_events(events_to_announce, show_game))
      end

      events # return events to mark "seen"
    end
  end

  def poll_lp_events # Poll Liquipedia soon™ events
    timers = (5..15).map{|i| "#{i}m"}
    filter_soon_events = ->(events : Array(ScEvent)) { events.select{|e| timers.includes?(e.timer)} }

    # don't announce events that are soon™ when the bot starts
    # (so that we can start and stop the bot several times in a row without spamming)
    current_events = filter_soon_events.call(run_category("levents") || [] of ScEvent).map &.id

    with_poller(current_events, "uevents") do |events|
      events_soon = filter_soon_events.call(events)
      lp_event_channels.each do |channel_id, games|
        events_to_announce = events_soon.select{|e| games.includes?(e.game)}
        events_to_announce.each do |e|
          details = fetch_details(e.id)
          extra = [e.timer.try{|t| "(#{t})"}]
          begin
            if details
              extra << details["subtext"].as_s?
              extra << details["lp"].as_s?.try{|lp| "<#{lp}>"}
            end
          rescue ex
            puts("Unable to extract details for event #{e.id}:\n#{ex.inspect_with_backtrace}")
          end
          safe_create_message(channel_id, " ** SOON ** #{e.name}\n#{extra.join(' ')}")
        end
      end
      events_soon # return events to mark "seen"
    end
  end

  def map_events(events)
    events.compact_map do |event|
      name = ScEvent.json_name(event)
      name_url = @aliases.fetch(name, nil)
      ScEvent.new(event["id"].as_s.to_i64, name, event["game"].as_s.upcase, event, name_url)
    end
  end

  def fetch_details(event_id)
    response = HTTP::Client.get("#{API_BASE_URL}/event/#{event_id}")
    if response.status_code != 200
      return nil
    end

    JSON.parse(response.body)
  end

  def fetch_category(name)
    response = HTTP::Client.get "#{API_BASE_URL}/#{name}"
    if response.status_code != 200
      return nil
    end

    JSON.parse(response.body)[name]
  end

  def run_category(name) : Array(ScEvent) | Nil
    fetch_category(name).try {|c| map_events(c) }
  end

  def run
    @client.on_message_create do |payload|
      puts "Received from #{payload.author.id}: #{payload.content}"
      parts = payload.content.split(" ")
      if payload.content == "!events"
        command_events(payload, false)
      elsif payload.content == "!events all"
        command_events(payload, true)
      elsif payload.content == "!help"
        command_help(payload)
      elsif payload.content == "!exit"
        command_exit(payload)
      elsif parts[0] == "!feature" && parts.size == 4
        command_feature(payload, parts[1], parts[2], parts[3])
      elsif parts[0] == "!feature" && parts.size == 2
        command_feature_query(payload, parts[1])
      elsif parts[0] == "!stream"
        parts.shift # remove "!stream"
        url = parts.pop
        command_stream(payload, parts.join(" "), url)
      end
    end
  end

  def with_throttle(key, delay, &block)
    now = Time.new
    if !@timers.has_key?(key) || @timers[key] + delay < now
      block.call
      @timers[key] = now
    end
  end

  def command_feature_query(payload, feature)
    return unless admin?(payload.author.id)
    channel = payload.channel_id

    hash = hash_for_feature(feature)
    unless hash
      safe_create_message(channel, "Invalid feature, try lp/events/announcements")
      return
    end
    games = hash.fetch(channel, %w())
    safe_create_message(channel, "Feature is " + (games.size > 0 ? "enabled for games #{games.join(", ")}." : "disabled."))
  end

  def command_feature(payload, feature, bool_str, games_str)
    return unless admin?(payload.author.id)
    channel = payload.channel_id

    bool_true = %w(on yes y + 1)
    bool_false = %w(off no n - 0)
    unless bool_true.includes?(bool_str) || bool_false.includes?(bool_str)
      safe_create_message(channel, "Invalid boolean value, try on/off")
      return
    end
    bool = bool_true.includes?(bool_str)

    games = games_str.upcase.split(',')
    return unless games.size < 1
    games = games.map(&.upcase).uniq
    unless games.all?{|g| GAMES.includes?(g)}
      safe_create_message(channel, "Invalid game(s). Try one of #{GAMES.join(", ")}.")
      return
    end

    hash = hash_for_feature(feature)
    unless hash
      safe_create_message(channel, "Invalid feature, try lp/events/announcements")
      return
    end

    # add/remove
    current_games = hash.fetch(channel, %w())
    updated_games = bool ? current_games + games : current_games - games
    new_games = updated_games.uniq
    hash[channel] = new_games
    @config.save!

    new_games_str = new_games.size > 0 ? "enabled for #{new_games.join(", ")}" : "disabled"
    safe_create_message(channel, "#{bool ? "Enabled" : "Disabled"} #{feature} for games #{games.join(", ")}. Now feature is #{new_games_str}.")
  end

  private def hash_for_feature(feature)
    case feature
    when "lp"
      lp_event_channels
    when "events"
      events_command
    when "announcements"
      announcements
    end
  end

  def command_exit(payload)
    return unless admin?(payload.author.id)
    Process.exit
  end

  def command_stream(payload, name, url)
    unless admin?(payload.author.id)
      puts("Unauthorized command from #{payload.author.id}")
      return
    end
    clean_url = url.lchop('<').rchop('>')
    @aliases[name] = clean_url
    safe_create_message(payload.channel_id, "Stream url of **#{name}** set to <#{clean_url}>")
  end

  def command_help(payload)
    channel = payload.channel_id
    return unless known_channel?(channel) # XXX means we can't get help for !feature, no big deal

    with_throttle("help/#{channel}", 20.seconds) do
      admin_help = admin?(payload.author.id) ? "\n * `!stream <event name> <event url>` - Changes the stream URL of an event\n * `!feature [lp|events|announcements] [on|off] <games>` - Enables or disable a bot feature for some (comma-separated) game(s)" : ""
      safe_create_message(channel, "Bot commands:\n * `!events` - Shows a list of today's events\n * `!events all` - Shows this week's events\n * `!help` - This command#{admin_help}")
    end
  end

  def command_events(payload, longterm)
    return unless events_command.has_key?(payload.channel_id)
    channel = payload.channel_id

    # TODO throttle should probably include channel id
    with_throttle("events/#{channel}", 20.seconds) do
      games = events_command[channel]
      show_game = games.size > 1 # show the game if there could be confusion
      {"levents" => "LIVE", "uevents" => "UPCOMING"}.each do |category, label|
        events = run_category(category)
        next unless events
        events_to_announce = filter_longterm(events.select{|e| games.includes?(e.game)}, longterm)
        if events_to_announce.size > 0
          safe_create_message(channel, " ** #{label} **\n" + format_events(events_to_announce[0..max_events], show_game))
        elsif category == "uevents"
          safe_create_message(channel, "No upcoming events for #{games.join(", ")}.")
        end
      end
    end
  end

  private def admin?(user_id)
    @config.admins.includes?(user_id)
  end

  private def known_channel?(channel)
    return true if announcements.has_key?(channel)
    return true if lp_event_channels.has_key?(channel)
    return true if events_command.has_key?(channel)
    return false
  end

  private def filter_longterm(events, longterm)
    if longterm
      events
    else # no longterm events, reject those with "d" in their timer
      events.reject{|e| e.timer.try{|t| t.includes?("d")}}
    end
  end

  private def safe_create_message(channel, message)
    begin
      @client.create_message(channel, message)
    rescue ex
      puts("Unable to create message on #{channel}")
    end
  end
end

ALIAS_LIST_FILE = "aliases.txt"
CONFIG_FILE = "config.json"

config = ScConfig.from_json(File.read(CONFIG_FILE))
config.filename = CONFIG_FILE

client = Discord::Client.new(token: "Bot #{ENV["SCALERT_TOKEN"]}", client_id: ENV["SCALERT_CLIENTID"].to_u64)
scalert = ScAlert.new(client, config, ALIAS_LIST_FILE)
spawn { scalert.poll_live_events }
spawn { scalert.poll_lp_events }
scalert.run
client.run
