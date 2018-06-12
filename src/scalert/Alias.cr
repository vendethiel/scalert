class Alias
  def initialize(@filename : String)
    @aliases = {} of String => String
    puts("loading alias list from #{filename}")
    begin
      File.each_line(filename, chomp: true) do |line|
        parts = line.split('=', 2)
        @aliases[parts[0]] = parts[1]
      end
    rescue ex
      puts("Unable to open file:\n#{ex.inspect_with_backtrace}")
    end
  end

  delegate :fetch, :[], :has_key?, :delete, to: @aliases
  def []=(key, value)
    @aliases[key] = value
    save!
  end

  private def save!
    File.write(@filename, self.to_s)
  end

  def to_s
    @aliases.map { |e| "#{e[0]}=#{e[1]}" }.join("\n")
  end
end

