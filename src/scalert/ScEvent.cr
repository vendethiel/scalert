class ScEvent
  getter id : Int64
  getter name : String
  getter game : String
  getter timer : String?
  getter url : String?

  def initialize(@id, @name, @game, event)
    if event["timer"]?
        @timer = event["timer"].as_s
      @desc = @timer
    elsif url = event["url"].as_s?
      @url = url
    end
  end

  def show_game(include_game = false)
    include_game ? " (#{@game})" : ""
  end

  def to_s(include_game = false, override_desc = nil)
    "* #{name}#{show_game(include_game)}#{override_desc || desc}"
  end

  def desc
    if @timer
      " - #{@timer}"
    elsif @url
      " - <#{@url}>"
    else
      ""
    end
  end
end

class ScEventGroup
  def initialize(@events : Array(ScEvent))
  end

  def to_s(show_game)
    @events[0].to_s(show_game, " - #{desc}")
  end

  def desc
    @events.map{|e| e.timer }.join(", then ")
  end
end
