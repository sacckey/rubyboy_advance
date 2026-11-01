# frozen_string_literal: true

module RubyboyAdvance
  class Keypad
    def initialize(interrupt)
      @interrupt = interrupt
      @keys = 0x03FF
    end

    def read(addr)
      case addr[0]
      when 0 then @keys & 0x00FF
      when 1 then @keys >> 8
      end
    end
  end
end
