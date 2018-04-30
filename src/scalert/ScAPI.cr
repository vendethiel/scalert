require "./Alias"

class ScAPI
  def initialize(@stream_urls : Alias, @api_url : String)
  end

  def map_events(events)
    events.compact_map do |event|
      name = ScEvent.json_name(event)
      name_url = @stream_urls.fetch(name, nil)
      ScEvent.new(event["id"].as_s.to_i64, name, event["game"].as_s.upcase, event, name_url)
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

    JSON.parse(response.body)[name]
  end

  def run_category(name) : Array(ScEvent) | Nil
    fetch_category(name).try {|c| map_events(c) }
  end

end
