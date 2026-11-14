module Omochi
  module Docker
    class Error < StandardError; end
    class TimeoutError < Error; end
  end
end
