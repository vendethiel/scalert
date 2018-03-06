require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

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

  delegate :fetch, to: @aliases
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
  getter name : String
  getter desc : String

  def initialize(@name : String, @desc : String)
  end

  def to_s
    " * #{name} – #{desc}"
  end

  def self.json_name(event)
    event["name"].as_s
  end

  def self.json_desc(event, urls)
    if event["url"]?
      name = event["name"].as_s
      "<#{urls.fetch(name, event["url"].as_s)}>"
    elsif event["timer"].as_s.includes?("d") # exclude >=1d
      nil
    else
      event["timer"].as_s
    end
  end
end

class ScAlert
  CHANNEL_ID = 328555540831666178_u64
  ADMINS = [
    116306741058207744_u64 # Ven
  ]

  def initialize(@client : Discord::Client, alias_filename : String)
    @aliases = Alias.new(alias_filename)
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
          fnew_events = new_events.map &.to_s
          @client.create_message(CHANNEL_ID, " ** LIVE **\n" + fnew_events.join("\n"))
        end

        # update the events list
        current_events = events.map {|e| e.name}
      rescue e
        puts "Rescued exception\n#{e.message}"
      end
      sleep 5.minutes
    end
  end

  def map_events(events)
    events.compact_map do |event|
      next if event["game"].as_s != "sc2"
      desc = ScEvent.json_desc(event, @aliases)
      next unless desc
      ScEvent.new(ScEvent.json_name(event), desc)
    end
  end

  def fetch_category(name)
    response = HTTP::Client.get "http://elgrandeapidelteamliquid.herokuapp.com/#{name}"
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
    levents = run_category("levents")
    if levents && levents.size > 0
      flevents = levents.map &.to_s
      @client.create_message(payload.channel_id, " ** LIVE **\n" + flevents.join("\n"))
    else
      puts("no levents")
    end

    uevents = run_category("uevents")
    if uevents && uevents.size > 0
      fuevents = uevents.map &.to_s
      @client.create_message(payload.channel_id, " ** UPCOMING **\n" + fuevents.join("\n"))
    else
      puts("no uevents")
    end
  end
end

ALIAS_LIST_FILE = "aliases.txt"

client = Discord::Client.new(token: "Bot #{ENV["SCALERT_TOKEN"]}", client_id: ENV["SCALERT_CLIENTID"].to_u64)
scalert = ScAlert.new(client, ALIAS_LIST_FILE)
spawn { scalert.poll_events }
scalert.run
client.run
