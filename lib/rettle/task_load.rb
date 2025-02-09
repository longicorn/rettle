# frozen_string_literal: true

class Rettle
  module TaskLoad
    def exporter(data)
      raise UndefinedError
    end

    def export(data: nil, size: 1000, flush: false)
      @_export_cache ||= []
      @_export_cache << data if data

      if flush || @_export_cache.size >= size
        exporter(@_export_cache) if @_export_cache.size.nonzero?
        @_export_cache = []
      end
    end
  end
end
