require "./ScEvent"
require "./ScBot"

class ScPoller
  def initialize(@bot : ScBot)
  end

  delegate api, safe_create_message, to: @bot
  delegate announcements, lp_event_channels, admins, to: @bot.config

  private def poll_filter_events(events, games, channel_id)
    guild_id = @bot.channel_id_to_guild_id(channel_id)

    events_for_games = events.select{|e| games.includes?(e.game)}
    events_filtered = @bot.filter_events(events, guild_id)
    events_filtered
  end

  def with_poller(current_events, category, &block)
    puts("[#{category}] start events: #{current_events}")
    loop do
      begin
        events = api.run_category(category) || [] of ScEvent
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
    current_events = api.run_category("levents").try{|c| c.map &.id} || [] of Int64
    with_poller(current_events, "levents") do |events|
      begin
        # for each channel to announce on...
        announcements.each do |channel_id, games|
          events_to_announce = poll_filter_events(events, games, channel_id)
          next unless events_to_announce.size > 0

          show_game = games.size > 1 # show the game if there could be confusion
          safe_create_message(channel_id, " ** LIVE **\n" + @bot.format_events(events_to_announce, show_game))
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
    current_events = filter_soon_events.call(api.run_category("levents") || [] of ScEvent).map &.id

    with_poller(current_events, "uevents") do |events|
      events_soon = filter_soon_events.call(events)

      begin
        lp_event_channels.each do |channel_id, games|
          events_to_announce = poll_filter_events(events_soon, games, channel_id)
          events_to_announce.each do |e|
            details = api.fetch_details(e.id)
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

end
