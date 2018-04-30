# Converts between a Hash(String, Bool) and Hash(UInt64, Bool)
module BoolMapConverter
  def self.to_json(value : Hash(UInt64, Bool), json : JSON::Builder)
    json.object do
      value.each do |k, v|
        json.field k.to_s, v
      end
    end
  end

  def self.from_json(json : JSON::PullParser)
    hash = {} of UInt64 => Bool
    json.read_object do |key|
      hash[key.to_u64] = json.read_bool
    end
    hash
  end
end
