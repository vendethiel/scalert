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
    # block mode: true is allowlist, false is denylist
    filter_mode: {type: Hash(UInt64, Bool), converter: BoolMapConverter},
    filter_list: {type: Hash(UInt64, Array(String)), converter: GameHashConverter},
    admins: Array(UInt64)
  )
end


