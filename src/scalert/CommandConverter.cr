module CommandConverter
  def self.to_json(value : Hash(UInt64, Hash(String, String)), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k, v
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of UInt64 => Hash(String, String)
    json.read_object do |key|
      commands = {} of String => String
      json.read_object do |command|
        commands[command] = json.read_string
      end
      hash[key.to_u64] = commands
    end
    hash
  end
end


