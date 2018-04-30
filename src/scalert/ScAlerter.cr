require "./ScCommands"
require "./ScPoller"

class ScAlerter
  def initialize(@bot : ScBot)
    @commands = ScCommands.new(@bot)
    @poller = ScPoller.new(@bot)
  end

  def run
    spawn { @poller.poll_live_events }
    spawn { @poller.poll_lp_events }
    @commands.run # runs on the event loop, no need for a thread
  end
end

