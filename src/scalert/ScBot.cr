# This file is the "bot", it is comprised of many different helpers that the modules will utilize

class ScBot
  getter api : ScAPI
  getter config : ScConfig
  getter client : Discord::Client
  getter stream_urls : Alias

  def initialize(@client : Discord::Client, @config : ScConfig, @stream_urls : Alias, @api : ScAPI)
    @timers = {} of String => Time
  end

  def format_events(events, show_game)
    events.map{|e| e.to_s(show_game)}.join("\n")
  end

  def channel_id_to_guild_id(channel_id)
    channel = @client.get_channel(channel_id) # TODO resolve_channel
    channel.guild_id
  end

  def with_throttle(key, delay, &block)
    now = Time.new
    if !@timers.has_key?(key) || @timers[key] + delay < now
      block.call
      @timers[key] = now
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

