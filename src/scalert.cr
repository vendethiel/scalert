require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

API_BASE_URL = "http://elgrandeapidelteamliquid.herokuapp.com"

class Alias
  def initialize(@filename : String)
    @aliases = {} of String => String
    puts("loading alias list from #{filename}")
    begin
      File.each_line(filename, chomp: true) do |line|
        parts = line.split('=', 2)
        @aliases[parts[0]] = parts[1]
      end
    rescue e
      puts("Unable to open file:\n#{e.message}")
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
  getter desc : String
  getter game : String

  def initialize(@id, @name, @desc, @game)
  end

  def to_s(include_game = false)
    " * #{name}#{include_game ? " (#{@game})" : ""} – #{desc}"
  end

  def self.json_name(event)
    event["name"].as_s
  end

  def self.json_desc(event, urls)
    name = event["name"].as_s
    if event["timer"]?
      if event["timer"].as_s.includes?("d") # exclude >=1d
        nil
      else
        event["timer"].as_s
      end
    elsif event["url"]?
      "<#{urls.fetch(name, event["url"].as_s)}>"
    elsif urls.has_key?(name)
      "<#{urls[name]}>"
    else
      "(no url)"
    end
  end
end

class ScAlert
  ANNOUNCEMENTS = {
    328555540831666178_u64 => %w(sc2 bw)  # Test server, #general
    306615995466776586_u64 => %w(bw)      # FBW #announcements
  }
  EVENTS_COMMAND = {
    328555540831666178_u64 => %w(sc2 bw), # Test server #general
    421332119118151680_u64 => %w(sc2)     # Test server #command-events-sc2
    306259732153368576_u64 => %w(bw)      # FBW #general
  }
  ADMINS = [
    116306741058207744_u64, # Ven
    133280548951949312_u64, # Kuro
    117555772560244739_u64  # Light
  ]

  def initialize(@client : Discord::Client, alias_filename : String)
    @aliases = Alias.new(alias_filename)
  end

  def format_events(events, show_game)
    events.map{|e| e.to_s(show_game)}.join("\n")
  end

  def poll_events
    current_events = run_category("levents").try{|c| c.map &.name} || [] of String
    puts("start events: #{current_events}")
    loop do
      begin
        events = run_category("levents") || [] of ScEvent
        puts("current events: #{current_events}")
        puts("fetched events: #{events}")

        # Keep only events that havn't been announced yet (this is Array#-)
        new_events = events.reject{|e| current_events.includes?(e.name) }
        puts("new events: #{new_events}")
        if new_events.size > 0
          # for each channel to announce on...
          ANNOUNCEMENTS.each do |channel_id, games|
            events_to_announce = events.select{|e| games.includes?(e.game)}
            next unless events_to_announce.size > 0
            show_game = games.size > 1 # show the game if there could be confusion
            @client.create_message(channel_id, " ** LIVE **\n" + format_events(events_to_announce, show_game))
          end
        end

        # update the events list
        current_events += new_events.map(&.id)
        # TODO clear old events SOMEHOW (timer? only keep N latest IDs?)
      rescue e
        puts "Rescued exception\n#{e.message}"
      end
      sleep 5.minutes
    end
  end

  def map_events(events)
    events.compact_map do |event|
      desc = ScEvent.json_desc(event, @aliases)
      next unless desc
      ScEvent.new(event["id"].as_s.to_i64, ScEvent.json_name(event), desc, event["game"].as_s)
    end
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
      if parts[0] == "!events"
        command_events(payload)
      elsif parts[0] == "!stream" && parts.size == 3
        command_stream(payload, parts[1], parts[2])
      end
    end
  end

  def command_stream(payload, name, url)
    if !ADMINS.includes?(payload.author.id)
      puts("Unauthorized command from #{payload.author.id}")
      return
    end
    clean_url = url.lchop('<').rchop('>')
    @aliases[name] = clean_url
    @client.create_message(payload.channel_id, "Stream url of **#{name}** set to <#{clean_url}>")
  end

  def command_events(payload)
    return unless EVENTS_COMMAND.has_key?(payload.channel_id)
    games = EVENTS_COMMAND[payload.channel_id]
    show_game = games.size > 1 # show the game if there could be confusion
    {"levents" => "LIVE", "uevents" => "UPCOMING"}.each do |category, label|
      events = run_category(category)
      events_to_announce = events && events.select{|e| games.includes?(e.game)}
      next unless events_to_announce && events_to_announce.size > 0
      @client.create_message(payload.channel_id, " ** #{label} **\n" + format_events(events_to_announce, show_game))
    end
  end
end

ALIAS_LIST_FILE = "aliases.txt"

client = Discord::Client.new(token: "Bot #{ENV["SCALERT_TOKEN"]}", client_id: ENV["SCALERT_CLIENTID"].to_u64)
scalert = ScAlert.new(client, ALIAS_LIST_FILE)
spawn { scalert.poll_events }
scalert.run
client.run
