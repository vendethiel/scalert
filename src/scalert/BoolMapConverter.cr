# Converts between a Hash(String, Bool) and Hash(UInt64, Bool)
module BoolMapConverter
  def self.to_json(value : Hash(Discord::Snowflake, Bool), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k.value.to_s, v
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of Discord::Snowflake => Bool
    json.read_object do |key|
      hash[Discord::Snowflake.new(key.to_u64)] = json.read_bool
    end
    hash
  end
end
