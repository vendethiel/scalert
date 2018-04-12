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

module CommandConverter
  def self.to_json(value : Hash(UInt64, Hash(String, String)), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k, v
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of UInt64 => Hash(String, String)
    json.read_object do |key|
      commands = {} of String => String
      json.read_object do |command|
        commands[command] = json.read_string
      end
      hash[key.to_u64] = commands
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
    commands: {type: Hash(UInt64, Hash(String, String)), converter: CommandConverter},
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
      begin
        # for each channel to announce on...
        announcements.each do |channel_id, games|
          events_to_announce = events.select{|e| games.includes?(e.game)}
          next unless events_to_announce.size > 0
          show_game = games.size > 1 # show the game if there could be confusion
          safe_create_message(channel_id, " ** LIVE **\n" + format_events(events_to_announce, show_game))
        end
      rescue ex
        puts "Rescued live events poller exception\n#{ex.inspect_with_backtrace}"
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

      begin
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
      rescue ex
        puts "Rescued lp poller exception\n#{ex.inspect_with_backtrace}"
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
      next if payload.content == ""

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
      elsif payload.content == "!command"
        # TODO probably list commands (like !help, but only user-def commands?)
      elsif parts[0] == "!command" && parts.size > 1
        parts.shift # remove "!command"
        name = parts.shift.lstrip("!") # don't define commands starting with a ! (or any number thereof)
        command_manage_command(payload, name, parts.join(" "))
      elsif parts[0].starts_with?("!")
        # TODO try to extract a mention, so that "!asl <!@> (`payload.parse_mentions`)
        # See https://github.com/meew0/discordcr/pull/64

        name = parts.pop.lchop('!').lchop('!') # we remove ! twice, because !! is the prefix used if a guild has a command with a reserved name
        command_exec_command(payload, name, parts.join(" "))
      end
    end
  end

  COMMANDS = %w(events help exit feature stream command)

  private def channel_id_to_guild_id(channel_id)
    channel = @client.get_channel(channel_id) # TODO resolve_channel
    channel.guild_id
  end

  private def with_throttle(key, delay, &block)
    now = Time.new
    if !@timers.has_key?(key) || @timers[key] + delay < now
      block.call
      @timers[key] = now
    end
  end

  def command_exec_command(payload, command, rest)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    return unless guild_id # dm

    command_text = @config.commands.fetch(guild_id, {} of String => String).fetch(command, nil)
    if command_text
      # try to find who we're replying to...
      mentions = rest.scan(/<@!?(?<id>\d+)>/)
      reply_to = if mentions.size > 0 # use the first mention...
                   mentions[0][0] # the first match of the first mention
                 else
                   payload.author.id
                 end

      safe_create_message(channel_id, "<@#{reply_to}>: #{command_text}")
    else
      safe_create_message(channel_id, "<@#{payload.author.id}>: No such command.")
    end
  end

  def command_manage_command(payload, name, text)
    channel_id = payload.channel_id
    unless mod?(payload.author.id, channel_id)
      safe_create_message(channel_id, "Unauthorized.")
      return
    end
    return unless guild_id = channel_id_to_guild_id(channel_id) # dm
    has_commands = @config.commands.has_key?(guild_id)
    command_exists = has_commands && @config.commands[guild_id].has_key?(name)

    if text == ""
      # remove command
      if command_exists
        @config.commands[guild_id].delete(name)

        if @config.commands[guild_id].empty?
          @config.commands.delete(guild_id)
        end
        safe_create_message(channel_id, "Command removed.")
      else
        safe_create_message(channel_id, "No such command.")
      end
    elsif text.includes?("@everyone") || text.includes?("@here") || name.includes?("`") || name.includes?("@")
      # Let's prevent commands that try to ping everyone/here...
      safe_create_message(channel_id, "Invalid name/text.")
      return # no need to save config
    else
      @config.commands[guild_id] = {} of String => String unless has_commands # init hash if necessary
      @config.commands[guild_id][name] = text
      if command_exists
        safe_create_message(channel_id, "Command replaced.")
      else
        safe_create_message(channel_id, "Command added.")
      end
    end
    @config.save!
  end

  def command_feature_query(payload, feature)
    channel = payload.channel_id
    unless mod?(payload.author.id, channel)
      safe_create_message(channel, "Unauthorized.")
      return
    end

    hash = hash_for_feature(feature)
    unless hash
      safe_create_message(payload.channel_id, "Invalid feature, try lp/events/announcements")
      return
    end
    games = hash.fetch(channel, %w())
    safe_create_message(channel, "Feature is " + (games.size > 0 ? "enabled for games #{games.join(", ")}." : "disabled."))
  end

  def command_feature(payload, feature, bool_str, games_str)
    channel = payload.channel_id
    unless mod?(payload.author.id, channel)
      safe_create_message(channel, "Unauthorized.")
      return
    end

    bool_true = %w(on yes y + 1 enable start enter add <<)
    bool_false = %w(off no n - 0 disable stop leave rm remove)
    unless bool_true.includes?(bool_str) || bool_false.includes?(bool_str)
      safe_create_message(channel, "Invalid boolean value, try on/off")
      return
    end
    bool = bool_true.includes?(bool_str)

    games = games_str.upcase.split(',')
    if games.size < 1
      safe_create_message(channel, "Invalid game(s). Try one of #{GAMES.join(", ")}.")
      return
    end
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
    if bool && games.all? {|game| current_games.includes?(game) }
      safe_create_message(channel, "Feature already enabled for the given game(s).")
      return
    end
    if !bool && games.none? {|game| current_games.includes?(game) }
      safe_create_message(channel, "Feature already disabled for the given game(s).")
      return
    end
    updated_games = bool ? current_games + games : current_games - games
    new_games = updated_games.uniq
    hash[channel] = new_games
    @config.save!

    given_games = games.sort.join(", ") # games to enable/disable
    now_games = new_games.sort.join(", ") # games that are now enabled/disabled
    new_games_str = " Now feature is " + (new_games.size > 0 ? "enabled for #{now_games}." : "disabled.")
    new_games_message = given_games == now_games ? "" : new_games_str # Don't state it twice, if the command contained all the games that are now enabled
    safe_create_message(channel, "#{bool ? "Enabled" : "Disabled"} #{feature} for game(s) #{given_games}.#{new_games_message}")
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
    channel_id = payload.channel_id
    return unless known_channel?(channel_id) # XXX means we can't get help for !feature, no big deal

    with_throttle("help/#{channel_id}", 20.seconds) do
      mod_help = mod?(payload.author.id, channel_id) ? "\n * `!feature [lp|events|announcements] [on|off] [#{GAMES.join(",")},...]` - Enables or disable a bot feature for some (comma-separated) game(s)\n * `!command <command name> <command text>...` – Add a command with given text" : ""
      admin_help = admin?(payload.author.id) ? "\n * `!stream <event name>... <event url>` - Changes the stream URL of an event" : ""

      next unless guild_id = channel_id_to_guild_id(channel_id)
      # a commands hash should never be empty (we supposedly clear the empty ones). If at some point, we change that, we can use .fetch(guild_id, {}).empty? instead
      userdef_commands = @config.commands.has_key?(guild_id) ? "\n * Server commands: #{format_user_commands(@config.commands[guild_id].keys)}" : ""

      safe_create_message(channel_id, "Bot commands:\n * `!events` - Shows a list of today's events\n * `!events all` - Shows this week's events\n * `!help` - This command#{mod_help}#{admin_help}#{userdef_commands}")
    end
  end

  # Formats user commands (per-server commands). Prints "!cmd" if the name isn't reserved, "!!cmd" if it is.
  private def format_user_commands(commands)
    commands
      .map {|command| COMMANDS.includes?(command) ? "`!!#{command}`" : "`!#{command}`" }
      .join(", ")
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
          range = 0..max_events - 1 # -1 so that max=10 gives 10 events, not 11
          safe_create_message(channel, " ** #{label} **\n" + format_events(events_to_announce[range], show_game))
        elsif category == "uevents"
          safe_create_message(channel, "No upcoming events for #{games.join(", ")}.")
        end
      end
    end
  end

  private def mod?(user_id, channel_id)
    return true if admin?(user_id)
    begin
      return false unless guild_id = channel_id_to_guild_id(channel_id) # dm
      guild = @client.get_guild(guild_id) # TODO resolve_guild

      # A server owner is always an admin, even without a role with associated permissions.
      if guild.owner_id == user_id
        return true
      end

      member = @client.get_guild_member(guild_id, user_id) # TODO resolve_member
      guild.roles
        .select {|role| member.roles.includes?(role.id) || role.id == guild.id } # @everyone is a role with id=guild.id
        .any? {|role| role.permissions.manage_channels? || role.permissions.administrator? }
    rescue ex
      puts("Unable to check permissions for user=#{user_id} and channel=#{channel_id}")
      false
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
