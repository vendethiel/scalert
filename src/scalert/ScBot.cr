# This file is the "bot", it is comprised of many different helpers that the modules will utilize

class ScBot
  getter api : ScAPI
  getter config : ScConfig
  getter client : Discord::Client

  delegate stream_urls, to: @config

  def initialize(@client : Discord::Client, @config : ScConfig, @api : ScAPI)
    @timers = {} of String => Time
  end

  # resolves a channel and an event name to the channel's guild stream url for that name
  def channel_stream_link(event_name, channel_id, guild_id = nil)
    global_url = @config.stream_urls.fetch(event_name, nil)
    if global_url
      return " - <#{global_url}>"
    end

    if !guild_id
      return nil unless channel_id # accept nil
      guild_id = channel_id_to_guild_id(channel_id)
    end

    url = @config.stream_urls.fetch("#{guild_id}:#{event_name}", nil)
    url.try{|link| " - <#{link}>"}
  end

  def format_streams(streams, show_game, channel_id, guild_id)
    streams.map do |s|
      url = channel_stream_link(s.name, channel_id, guild_id)
      s.to_s(show_game, url)
    end.join("\n")
  end

  # format events for display. if a channel_id is included, tries to use per-guild event URL
  def format_events(events, show_game, channel_id = nil)
    events.map do |e|
      url = channel_stream_link(e.name, channel_id)
      e.to_s(show_game, url)
    end.join("\n")
  end

  # format event groups, don't ever use on LIVE events...
  def format_events_grouped(events, show_game)
    # here, we rely on the fact that Hash is ordered
    group_hash = events.group_by{|e| {e.game, e.name} }
    groups = group_hash.map{|(_, events)| ScEventGroup.new(events) }
    groups.map{|g| g.to_s(show_game) }.join("\n")
  end

  def channel_id_to_guild_id(channel_id)
    channel = @client.get_channel(channel_id) # TODO resolve_channel
    channel.guild_id
  end

  def with_throttle(key, delay, &block)
    now = Time.new
    if !@timers.has_key?(key) || @timers[key] + delay < now
      @timers[key] = now
      block.call
    end
  end

  def mod?(user_id, channel_id)
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

  def admin?(user_id)
    @config.admins.includes?(user_id)
  end

  def known_channel?(channel)
    return true if @config.announcements.has_key?(channel)
    return true if @config.lp_event_channels.has_key?(channel)
    return true if @config.events_command.has_key?(channel)
    return false
  end

  def filter_longterm(events, longterm)
    if longterm
      events
    else # no longterm events, reject those with "d" in their timer
      events.reject{|e| e.timer.try{|t| t.includes?("d")}}
    end
  end

  # filter events based on black/white lists
  def filter_events(events, guild_id)
    return events unless @config.filter_mode.has_key?(guild_id)
    return events unless @config.filter_list.has_key?(guild_id)
    list = @config.filter_list[guild_id]
    # allow
    if @config.filter_mode[guild_id]
      events.select{|e| list.includes?(e.name) }
    else
    # deny
      events.reject{|e| list.includes?(e.name) }
    end
  end

  def safe_create_message(channel, message)
    begin
      @client.create_message(channel, message)
    rescue ex
      puts("Unable to create message on #{channel}")
    end
  end
end


