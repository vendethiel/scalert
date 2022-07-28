class ScConfig
  setter filename : String | Nil
  def save!
    puts("Saving config to #{CONFIG_FILE}")

    filename = @filename
    unless filename # means someome changed the config loading code
      print "No config file" 
      Process.exit 1
    end
    File.write(filename, to_pretty_json)
  end

  JSON.mapping(
    max_events: Int32,
    announcements: {type: Hash(Discord::Snowflake, Array(String)), converter: GameHashConverter},
    events_command: {type: Hash(Discord::Snowflake, Array(String)), converter: GameHashConverter},
    lp_event_channels: {type: Hash(Discord::Snowflake, Array(String)), converter: GameHashConverter},
    streams_command: {type: Hash(Discord::Snowflake, Array(String)), converter: GameHashConverter},
    commands: {type: Hash(Discord::Snowflake, Hash(String, String)), converter: CommandConverter},
    # block mode: true is allowlist, false is denylist
    filter_mode: {type: Hash(Discord::Snowflake, Bool), converter: BoolMapConverter},
    filter_list: {type: Hash(Discord::Snowflake, Array(String)), converter: GameHashConverter},
    admins: Array(UInt64),
    stream_urls: Hash(String, String),
    banlist: Array(UInt64),
  )
end


