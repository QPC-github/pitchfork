# -*- encoding: binary -*-
require "raindrops"

# This class and its members can be considered a stable interface
# and will not change in a backwards-incompatible fashion between
# releases of unicorn.  Knowledge of this class is generally not
# not needed for most users of unicorn.
#
# Some users may want to access it in the before_fork/after_fork hooks.
# See the Unicorn::Configurator RDoc for examples.
class Unicorn::Worker
  # :stopdoc:
  attr_accessor :nr, :switched
  attr_reader :to_io # IO.select-compatible
  attr_reader :master

  PER_DROP = Raindrops::PAGE_SIZE / Raindrops::SIZE
  DROPS = []

  def initialize(nr, pipe=nil)
    drop_index = nr / PER_DROP
    @raindrop = DROPS[drop_index] ||= Raindrops.new(PER_DROP)
    @offset = nr % PER_DROP
    @raindrop[@offset] = 0
    @nr = nr
    @switched = false
    @to_io, @master = pipe || Unicorn.pipe
  end

  def atfork_child # :nodoc:
    # we _must_ close in child, parent just holds this open to signal
    @master = @master.close
  end

  # master fakes SIGQUIT using this
  def quit # :nodoc:
    @master = @master.close if @master
  end

  # parent does not read
  def atfork_parent # :nodoc:
    @to_io = @to_io.close
  end

  # call a signal handler immediately without triggering EINTR
  # We do not use the more obvious Process.kill(sig, $$) here since
  # that signal delivery may be deferred.  We want to avoid signal delivery
  # while the Rack app.call is running because some database drivers
  # (e.g. ruby-pg) may cancel pending requests.
  def fake_sig(sig) # :nodoc:
    old_cb = trap(sig, "IGNORE")
    old_cb.call
  ensure
    trap(sig, old_cb)
  end

  # master sends fake signals to children
  def soft_kill(sig) # :nodoc:
    case sig
    when Integer
      signum = sig
    else
      signum = Signal.list[sig.to_s] or
          raise ArgumentError, "BUG: bad signal: #{sig.inspect}"
    end

    # writing and reading 4 bytes on a pipe is atomic on all POSIX platforms
    # Do not care in the odd case the buffer is full, here.
    begin
      @master.write_nonblock([signum].pack('l'), exception: false)
    rescue Errno::EPIPE
      # worker will be reaped soon
    end
  end

  # this only runs when the Rack app.call is not running
  # act like a listener
  def accept_nonblock(exception: nil) # :nodoc:
    loop do
      case buf = @to_io.read_nonblock(4, exception: false)
      when :wait_readable # keep waiting
        return false
      when nil # EOF master died, but we are at a safe place to exit
        fake_sig(:QUIT)
      end

      case buf
      when String
        # unpack the buffer and trigger the signal handler
        signum = buf.unpack('l')
        fake_sig(signum[0])
        # keep looping, more signals may be queued
      else
        raise TypeError, "Unexpected read_nonblock returns: #{buf.inspect}"
      end
    end # loop, as multiple signals may be sent
  end

  # worker objects may be compared to just plain Integers
  def ==(other_nr) # :nodoc:
    @nr == other_nr
  end

  # called in the worker process
  def tick=(value) # :nodoc:
    @raindrop[@offset] = value
  end

  # called in the master process
  def tick # :nodoc:
    @raindrop[@offset]
  end

  # called in both the master (reaping worker) and worker (SIGQUIT handler)
  def close # :nodoc:
    @master.close if @master
    @to_io.close if @to_io
  end
end
