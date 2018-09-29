class ScEvent
  getter id : Int64
  getter name : String
  getter game : String
  getter timer : String?
  getter url : String?

  def initialize(@id, @name, @game, event, name_url)
    if event["timer"]?
        @timer = event["timer"].as_s
      @desc = @timer
    elsif name_url # by-name stream URL
      @url = name_url
    elsif event["url"]?
      @url = event["url"].as_s
    end
  end

  def show_game(include_game = false)
    include_game ? " (#{@game})" : ""
  end

  def to_s(include_game = false, override_desc = nil)
    " * #{name}#{show_game(include_game)} #{override_desc || desc}"
  end

  def desc
    if @timer
      "- #{@timer}"
    elsif @url
      "- <#{@url}>"
    else
      ""
    end
  end

  def self.json_name(event)
    event["name"].as_s
  end
end

class ScEventGroup
  def initialize(@events : Array(ScEvent))
  end

  # LOL if your .to_s has no side effects
  def to_s(show_game)
    @events[0].to_s(show_game, @events.map{|e| e.desc }.join(", "))
  end
end
