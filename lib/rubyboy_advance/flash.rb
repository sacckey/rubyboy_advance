# frozen_string_literal: true

module RubyboyAdvance
  class Flash
    def initialize
      @ram = Array.new(0x10000, 0xFF)
    end

    def read(addr)
      @ram[addr]
    end

    def write(addr, value)
      @ram[addr] = value
    end
  end
end
