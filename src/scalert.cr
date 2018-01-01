require "json"
require "http/client"

require "./scalert/*"
require "../lib/discordcr/src/discordcr" # include dep
require "../lib/discordcr/src/discordcr/*" # include dep

module Scalert
  extend self

  CHANNEL_ID = 328555540831666178_u64

  def event_name(event)
    event["name"].as_s
  end

  def poll_events(client)
    current_events = run_category("levents") || [] of String
    loop do
      events = run_category("levents") || [] of String
      puts("fetched events: #{events}")

      # Keep only events that havn't been announced yet
      new_events = events - current_events
      if new_events.size > 0
        client.create_message(CHANNEL_ID, " ** LIVE **\n" + new_events.join("\n"))
      end

      # update the events list
      current_events = events
      sleep 5.minutes
    end
  end

  def map_events(events)
      events.map do |event|
        next if event["game"].as_s != "sc2"
        str = if event["url"]?
                "<#{event["url"].as_s}>"
              else
                next if event["timer"].as_s.includes?("d") # exclude >=1d
                event["timer"].as_s
              end
        "  * #{event_name(event)} – #{str}"
      end.compact
  end

  def fetch_category(name)
    response = HTTP::Client.get "http://elgrandeapidelteamliquid.herokuapp.com/#{name}"
    if response.status_code != 200
      #client.create_message(payload.channel_id, "Error fetching TL API data")
      return nil
    end

    JSON.parse(response.body)[name]
  end

  def run_category(name)
    fetch_category(name).try {|c| map_events(c) }
  end


  def run(client)
    client.on_message_create do |payload|
      puts "Received #{payload.content}"
      if payload.content == "!events"

        levents = run_category("levents")
        if levents && levents.size > 0
          client.create_message(payload.channel_id, " ** LIVE **\n" + levents.join("\n"))
        else
          puts("no levents")
        end

        uevents = run_category("uevents")
        if uevents && uevents.size > 0
          client.create_message(payload.channel_id, " ** UPCOMING **\n" + uevents.join("\n"))
        else
          puts("no uevents")
        end

      end
    end
  end
end

client = Discord::Client.new(token: "Bot #{ENV["SCALERT_TOKEN"]}", client_id: ENV["SCALERT_CLIENTID"].to_u64)
Scalert.run(client)
spawn { Scalert.poll_events(client) }
client.run
