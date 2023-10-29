class ScStream
  getter name : String
  getter game : String
  getter url : String
  getter viewers : Int64
  getter featured : Bool

  def initialize(@name, @game, @url, @viewers, @featured)
  end

  def to_s(include_game, override_url = nil)
    "* #{name}#{show_game(include_game)}#{override_url || show_url}#{show_viewers}"
  end

  def show_url
    if url == ""
      ""
    else
      " - <#{url}>"
    end
  end

  def show_viewers
    if viewers == 0
      ""
    elsif viewers == 1
      " (1 viewer)"
    else
      " (#{viewers} viewers)"
    end
  end

  def show_game(include_game = false)
    include_game ? " (#{@game})" : ""
  end
end
