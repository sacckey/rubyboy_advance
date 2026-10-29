# frozen_string_literal: true

module RubyboyAdvance
  class Flash128
    # Maker and device ID of a Sanyo chip, as mGBA reports
    ID = [0x62, 0x13].freeze

    def initialize
      @ram = Array.new(0x20000, 0xFF)
      @bank = 0
      @command = 0
      @command_step = 0
    end

    def read(addr)
      @command == 0x90 && addr < 2 ? ID[addr] : @ram[ram_offset(addr)]
    end

    def write(addr, value)
      if @command == 0xA0
        @ram[ram_offset(addr)] = value
        @command = 0
      elsif @command == 0xB0
        @bank = value[0]
        @command = 0
      elsif @command_step == 2
        if @command == 0x80
          case value
          when 0x10 then @ram.fill(0xFF)
          when 0x30 then @ram.fill(0xFF, ram_offset(addr & 0xF000), 0x1000)
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

    private

    def ram_offset(addr)
      addr + (@bank * 0x10000)
    end
  end
end
