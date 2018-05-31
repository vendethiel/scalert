class ScCommands
  COMMANDS = %w(events help exit feature stream command)
  BOOL_TRUE = %w(on yes y + 1 enable start enter add <<)
  BOOL_FALSE = %w(off no n - 0 disable stop leave rm remove)

  def initialize(@bot : ScBot)
  end

  delegate client, api, config, stream_urls, to: @bot
  delegate safe_create_message, filter_longterm, known_channel?, mod?, admin?, channel_id_to_guild_id, to: @bot
  delegate max_events, events_command, lp_event_channels, announcements, to: @bot.config

  def run
    client.on_message_create do |payload|
      puts "Received from #{payload.author.id}: #{payload.content}"
      next if payload.content == ""

      parts = payload.content.split(" ")
      if payload.content == "!events"
        command_events(payload, false)
      elsif payload.content == "!events all"
        command_events(payload, true)
      elsif parts[0] == "!event" && parts.size > 1
        parts.shift
        command_event_next(payload, parts.join(" "))

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

      elsif parts[0] == "!filter" && parts.size == 2 && parts[1] == "mode"
        command_filter_mode_query(payload)
      elsif parts[0] == "!filter" && parts.size == 3 && parts[1] == "mode"
        command_filter_mode(payload, parts[2])
      elsif parts[0] == "!filter" && parts.size > 2
        parts.shift # remove "!filter"
        bool = parts.shift
        command_filter_manage(payload, bool, parts.join(" "))

      elsif payload.content == "!command"
        # TODO probably list commands (like !help, but only user-def commands?)
      elsif parts[0] == "!command" && parts.size > 1
        parts.shift # remove "!command"
        name = parts.shift.lstrip("!") # don't define commands starting with a ! (or any number thereof)
        command_manage_command(payload, name, parts.join(" "))

      elsif parts[0].starts_with?("!")
        # TODO try to extract a mention, so that "!foo <!@> (`payload.parse_mentions`) can reply
        # See https://github.com/meew0/discordcr/pull/64

        name = parts.shift.lchop('!').lchop('!') # we remove ! twice, because !! is the prefix used if a guild has a command with a reserved name
        next if name.lstrip('!') == "" # no command, just someone too excited
        command_exec_command(payload, name, parts.join(" "))
      end
    end
  end

  def command_filter_mode_query(payload)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    return unless guild_id # dm

    unless mod?(payload.author.id, channel_id)
      safe_create_message(channel_id, "Unauthorized.")
      return
    end

    has_mode = config.filter_mode.has_key?(guild_id)
    has_list = config.filter_list.has_key?(guild_id)
    entries = has_list ? config.filter_list[guild_id].size : 0
    entries_str = "#{entries} #{entries == 1 ? "entry" : "entries"}"
    if has_mode && config.filter_mode[guild_id]
      if entries == 0
        safe_create_message(channel_id, "*Warning*! Filtering in allow-only mode, but the list is empty. This means no events will be listed/announced.")
      else
        safe_create_message(channel_id, "Filtering in allow-only mode, with #{entries_str}.")
      end
    elsif has_mode
      safe_create_message(channel_id, "Filtering in block-only mode, with #{entries_str}.")
    else
      if entries == 0
        safe_create_message(channel_id, "Filtering disabled.")
      else
        safe_create_message(channel_id, "Filtering disabled, so allow events will be listed/announced, but the list has #{entries_str}.")
      end
    end
  end

  def command_filter_mode(payload, mode)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    return unless guild_id # dm

    unless mod?(payload.author.id, channel_id)
      safe_create_message(channel_id, "Unauthorized.")
      return
    end

    if %w(allow accept).includes?(mode)
      safe_create_message(channel_id, "Filter now in accept-list mode.")
      config.filter_mode[guild_id] = true
    elsif %w(deny block).includes?(mode)
      safe_create_message(channel_id, "Filter now in deny-list mode.")
      config.filter_mode[guild_id] = false
    elsif BOOL_FALSE.includes?(mode)
      safe_create_message(channel_id, "Disabled filtering")
      config.filter_mode.delete(guild_id) # disable filter
    else
      safe_create_message(channel_id, "Invalid value, allowed: allow/deny/off.")
      return
    end

    unless config.filter_list.has_key?(guild_id)
      config.filter_list[guild_id] = [] of String
    end
    config.save!
  end

  def command_filter_manage(payload, bool_str, name)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    return unless guild_id # dm

    unless mod?(payload.author.id, channel_id)
      safe_create_message(channel_id, "Unauthorized.")
      return
    end

    unless config.filter_mode.has_key?(guild_id)
      safe_create_message(channel_id, "Configure filter via `!filter mode` first.")
      return
    end

    unless config.filter_list.has_key?(guild_id)
      config.filter_list[guild_id] = %w()
    end
    hash = config.filter_list[guild_id]

    if BOOL_TRUE.includes?(bool_str)
      if hash.includes?(name)
        safe_create_message(channel_id, "Value is already in the list.")
      else
        hash.push(name)
        safe_create_message(channel_id, "Value added to the list.")
        config.save!
      end
    elsif BOOL_FALSE.includes?(bool_str)
      if config.filter_list[guild_id].delete(name)
        safe_create_message(channel_id, "Value removed from the list.")
        config.save!
      else
        safe_create_message(channel_id, "Value not present in the list.")
      end
    else
      safe_create_message(channel_id, "Invalid boolean: use add/remove.")
    end
    # we already saved
  end

  def command_exec_command(payload, command, rest)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    return unless guild_id # dm

    command_text = config.commands.fetch(guild_id, {} of String => String).fetch(command, nil)
    if command_text
      @bot.with_throttle("guild_command/#{guild_id}/#{command}", 20.seconds) do
        # try to find who we're replying to...
        mentions = rest.scan(/<@!?(?<id>\d+)>/)
        reply_to = if mentions.size > 0 # use the first mention...
                     mentions[0][1] # the first match of the first mention
                   else
                     payload.author.id
                   end

        safe_create_message(channel_id, "<@#{reply_to}>: #{command_text}")
      end
    else
      # While this looks like a good idea... It means cohabitation with any other bot is a nuisance. Let's not.
      #safe_create_message(channel_id, "<@#{payload.author.id}>: No such command.")
    end
  end

  def command_manage_command(payload, name, text)
    channel_id = payload.channel_id
    unless mod?(payload.author.id, channel_id)
      safe_create_message(channel_id, "Unauthorized.")
      return
    end
    return unless guild_id = channel_id_to_guild_id(channel_id) # dm
    has_commands = config.commands.has_key?(guild_id)
    command_exists = has_commands && config.commands[guild_id].has_key?(name)

    if text == ""
      # remove command
      if command_exists
        config.commands[guild_id].delete(name)

        if config.commands[guild_id].empty?
          config.commands.delete(guild_id)
        end
        safe_create_message(channel_id, "Command removed.")
      else
        safe_create_message(channel_id, "No such command.")
      end
    elsif text.includes?("@everyone") || text.includes?("@here") || name.includes?("`") || name.includes?("@")
      # Let's prevent commands that try to ping everyone/here, or are named with an @
      safe_create_message(channel_id, "Invalid name/text.")
      return # no need to save config
    else
      unless has_commands # init hash if necessary
        config.commands[guild_id] = {} of String => String
      end
      config.commands[guild_id][name] = text
      if command_exists
        safe_create_message(channel_id, "Command replaced.")
      else
        safe_create_message(channel_id, "Command added.")
      end
    end
    config.save!
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

    unless BOOL_TRUE.includes?(bool_str) || BOOL_FALSE.includes?(bool_str)
      safe_create_message(channel, "Invalid boolean value, try on/off")
      return
    end
    bool = BOOL_TRUE.includes?(bool_str)

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
    config.save!

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
    stream_urls[name] = clean_url
    safe_create_message(payload.channel_id, "Stream url of **#{name}** set to <#{clean_url}>")
  end

  def command_help(payload)
    channel_id = payload.channel_id

    @bot.with_throttle("help/#{channel_id}", 20.seconds) do
      mod_help = mod?(payload.author.id, channel_id) ? "\n * `!feature [lp|events|announcements] [on|off] [#{GAMES.join(",")},...]` - Enables or disable a bot feature for some (comma-separated) game(s)\n * `!command <command name> <command text>...` – Add a command with given text\n * `!filter mode [off|allow|deny]` - Sets the filter list to allow/deny or disables it.\n * `!filter [add|remove] <event name>...` - Adds or removes the event from the filter list." : ""
      admin_help = admin?(payload.author.id) ? "\n * `!stream <event name>... <event url>` - Changes the stream URL of an event" : ""

      next unless guild_id = channel_id_to_guild_id(channel_id)
      # a commands hash should never be empty (we supposedly clear the empty ones). If at some point, we change that, we can use .fetch(guild_id, {}).empty? instead
      userdef_commands = config.commands.has_key?(guild_id) ? "\n * Server commands: #{format_user_commands(config.commands[guild_id].keys)}" : ""

      safe_create_message(channel_id, "Bot commands:\n * `!events` - Shows a list of today's events\n * `!events all` - Shows this week's events\n * `!event <event name>...` - Timers for a specific event\n * `!help` - This command#{mod_help}#{admin_help}#{userdef_commands}")
    end
  end

  # Formats user commands (per-server commands). Prints "!cmd" if the name isn't reserved, "!!cmd" if it is.
  private def format_user_commands(commands)
    commands
      .map {|command| COMMANDS.includes?(command) ? "`!!#{command}`" : "`!#{command}`" }
      .join(", ")
  end

  def command_event_next(payload, event_name)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)
    #TODO with_throttle?

    # need !events to be enabled, so we can find which games to show
    return unless events_command.has_key?(payload.channel_id)

    games = events_command[channel_id]
    show_game = games.size > 1 # plural yada yada
    live_events = api.run_category("levents").try{|ev| ev.select{|e| games.includes?(e.game)}}
    return unless live_events
    up_events = api.run_category("uevents").try{|ev| ev.select{|e| games.includes?(e.game)}}
    return unless up_events

    found_fuzzy = false
    message_parts = [] of String

    # the event might be currently live
    live_events_filtered = live_events.select{|e| e.name == event_name }
    if live_events_filtered.size == 0
      # no exact match, let's try fuzzy matching
      live_events_filtered = live_events.select{|e| e.name.starts_with?(event_name) }
      if live_events_filtered.size > 0
        # we got a fuzzy match. Mark it as fuzzy, so that upcoming knows to force fuzzy.
        # this is to prevent i.e. LIVE to use a partial match, and then UPCOMING to find a different event via perfect match
        found_fuzzy = true
      end
    end

    has_live_events = live_events_filtered.size > 0
    # now process live events
    if live_events_filtered.size > 0
      live_event = live_events_filtered[0]
      message_parts << "Currently live: #{live_event.name}#{live_event.show_game(show_game)} #{live_event.desc}"
    end

    # the event might be upcoming
    live_perfect_matches = up_events.select{|e| e.name == event_name }
    live_fuzzy_matches = up_events.select{|e| e.name.starts_with?(event_name) }
    # if we know we found a fuzzy match for LIVE, force fuzzy
    up_events_filtered = found_fuzzy || live_perfect_matches.size == 0 ? live_fuzzy_matches : live_perfect_matches

    # we found 2+ matches, make sure they're from the same game
    # this might bring us back to a single event only.
    if up_events_filtered.size >= 2
      up_events_filtered = up_events_filtered.select{|e| e.game == up_events_filtered[0].game }
    end

    # now process
    if up_events_filtered.size >= 2
      event1 = up_events_filtered[0]
      event2 = up_events_filtered[1]
      if event1.name == event2.name
        # two instances of the same event
        # force show_game to false, don't repeat game name
        message_parts << "Upcoming: #{event1.name}#{event1.show_game(show_game)} in #{event1.timer}, then #{event2.timer}."
      else
        # different events, fuzzy matched
        message_parts << "Upcoming: #{event1.name}#{event1.show_game(show_game)} in #{event1.timer}, then #{event2.name} in #{event2.timer}."
      end
    elsif up_events_filtered.size == 1
      event = up_events_filtered[0]
      message_parts << "Upcoming: #{event.name}#{event.show_game(show_game)} in #{event.timer}."
    else
      if has_live_events
        message_parts << "No other event planned afterwards this week."
      else
        message_parts << "No such event upcoming this week."
      end
    end

    safe_create_message(payload.channel_id, message_parts.join("\n"))
  end

  private def events_display(channel_id, label, events, show_game)
    range = 0..max_events - 1 # -1 so that max=10 gives 10 events, not 11
    safe_create_message(channel_id, " ** #{label} **\n" + @bot.format_events(events[range], show_game))
  end

  def command_events(payload, longterm)
    return unless events_command.has_key?(payload.channel_id)
    channel_id = payload.channel_id
    guild_id = channel_id_to_guild_id(channel_id)

    @bot.with_throttle("events/#{longterm}/#{channel_id}", 20.seconds) do
      games = events_command[channel_id]
      show_game = games.size > 1 # show the game if there could be confusion
      {"levents" => "LIVE", "uevents" => "UPCOMING"}.each do |category, label|
        events = api.run_category(category)
        next unless events

        events_for_game = events.select{|e| games.includes?(e.game)}
        events_filtered = @bot.filter_events(events_for_game, guild_id)
        events_filtered_longterm = filter_longterm(events_filtered, longterm)

        if events_filtered_longterm.size > 0
          events_display(channel_id, label, events_filtered_longterm, show_game)
        elsif category == "uevents"
          if events_filtered.size > 0 # we're in !longterm, but there are longterm events
            events_display(channel_id, label, events_filtered, show_game)
          elsif longterm
            safe_create_message(channel_id, "No upcoming events for #{games.join(", ")} this week")
          else
            safe_create_message(channel_id, "No upcoming events for #{games.join(", ")} today.")
          end
        end
      end
    end
  end

end