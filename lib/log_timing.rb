module LogTiming
  def self.measure(label, logger: LOGGER, level: :debug)
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    logger.public_send(level, "#{label} took=#{ms}ms")
    result
  end
end
