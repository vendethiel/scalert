class ScAPI
  def initialize(@api_url : String)
  end

  def map_events(events)
    events.map do |event|
      ScEvent.new(event["id"].as_s.to_i64, event["name"].as_s, event["game"].as_s.upcase, event)
    end
  end

  def map_streams(streams)
    streams.map do |stream|
      ScStream.new(stream["streamer"].as_s, stream["game"].as_s.upcase, stream["url"].as_s,
                   stream["viewers"].as_i64, stream["featured"].as_bool)
    end
  end

  def fetch_details(event_id)
    response = HTTP::Client.get("#{@api_url}/event/#{event_id}")
    if response.status_code != 200
      return nil
    end

    JSON.parse(response.body)
  end

  def fetch_category(name)
    response = HTTP::Client.get "#{@api_url}/#{name}"
    if response.status_code != 200
      return nil
    end

    JSON.parse(response.body)[name].as_a
  end

  def fetch_streams
    response = HTTP::Client.get("#{@api_url}/streams")
    if response.status_code != 200
      return nil
    end

    JSON.parse(response.body).as_a
  end

  def run_streams : Array(ScStream) | Nil
    fetch_streams.try {|c| map_streams(c) }
  end

  def run_category(name) : Array(ScEvent) | Nil
    fetch_category(name).try {|c| map_events(c) }
  end

end
