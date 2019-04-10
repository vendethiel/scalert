module CommandConverter
  def self.to_json(value : Hash(Discord::Snowflake, Hash(String, String)), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k.value.to_s, v
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of Discord::Snowflake => Hash(String, String)
    json.read_object do |key|
      commands = {} of String => String
      json.read_object do |command|
        commands[command] = json.read_string
      end
      hash[Discord::Snowflake.new(key.to_u64)] = commands
    end
    hash
  end
end


