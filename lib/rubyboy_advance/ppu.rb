# frozen_string_literal: true

module RubyboyAdvance
  class Ppu
    attr_reader :buffer

    def initialize
      @cycles = 0
      @line = 0
      @io = Array.new(0x60, 0)
      @palram = Array.new(0x400, 0)
      @vram = Array.new(0x18000, 0)
      @oam = Array.new(0x400, 0)
      @buffer = Array.new(240 * 160, 0x7FFF)
    end

    def step(cycles)
      res = false
      @cycles += cycles

      while @cycles >= 1232
        @cycles -= 1232
        @line += 1
        if @line == 160
          res = true
          dispcnt = read_io16(0)
          case dispcnt & 0x7
          when 3
            (160 * 240).times do |i|
              @buffer[i] = @vram[i << 1] | (@vram[(i << 1) + 1] << 8)
            end
          end
        end
        @line = 0 if @line == 228
      end

      res
    end

    def read_io(offset)
      @io[offset]
    end

    def read_io16(offset)
      @io[offset] + (@io[offset + 1] << 8)
    end

    def write_io(offset, value)
      @io[offset] = value
    end

    def read_palram(addr)
      @palram[addr & 0x3FF]
    end

    def write_palram(addr, value)
      @palram[addr & 0x3FF] = value
    end

    def read_vram(addr)
      @vram[vram_index(addr)]
    end

    def write_vram(addr, value)
      @vram[vram_index(addr)] = value
    end

    def read_oam(addr)
      @oam[addr & 0x3FF]
    end

    def write_oam(addr, value)
      @oam[addr & 0x3FF] = value
    end

    private

    def vram_index(addr)
      addr[16] == 0 ? addr & 0xFFFF : addr & 0x17FFF
    end
  end
end
