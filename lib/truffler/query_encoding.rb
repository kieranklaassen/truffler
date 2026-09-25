module Truffler
  # Query encoding (KTD9, KTD10): Jev turns a query into label filters,
  # boosts, a sparse intent vector, and keyword splits. Keystroke search only
  # reads the cached result; a miss hands the query to `Prefetch`, which
  # enqueues one `EncodeQueryJob` per in-flight window.
  module QueryEncoding
    IN_FLIGHT_TTL = 2.minutes
    DEFAULT_FILTER_AT = 0.5
    DEFAULT_BOOST = 1.0
    MAX_TOKEN_QUESTIONS = 12
  end
end
