# frozen_string_literal: true

module RubyboyAdvance
  class Flash
    def initialize
      @ram = Array.new(0x10000, 0xFF)
      @command = 0
      @command_step = 0
    end

    def read(addr)
      @ram[addr]
    end

    def write(addr, value)
      if @command == 0xA0
        @ram[addr] = value
        @command = 0
      elsif @command_step == 2
        if @command == 0x80
          case value
          when 0x10 then @ram.fill(0xFF)
          when 0x30 then @ram.fill(0xFF, addr & 0xF000, 0x1000)
          end
        end

        @command = value
        @command_step = 0
      elsif addr == 0x2AAA && value == 0x55 && @command_step == 1
        @command_step = 2
      elsif addr == 0x5555 && value == 0xAA && @command_step == 0
        @command_step = 1
      end
    end
  end
end
