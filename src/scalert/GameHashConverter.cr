# Converts between a Hash(String, Array(String)) and Hash(UInt64, Array(String))
# XXX that Array(String) probably wants to be an Array(Game enum)
module GameHashConverter
  def self.to_json(value : Hash(UInt64, Array(String)), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k.to_s do
          json.array do
            v.each {|game| json.string(game)}
          end
        end
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of UInt64 => Array(String)
    json.read_object do |key|
      games = [] of String
      json.read_array do
        games << json.read_string
      end
      hash[key.to_u64] = games
    end
    hash
  end
end

