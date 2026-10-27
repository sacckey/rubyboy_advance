# frozen_string_literal: true

module RubyboyAdvance
  class Ppu
    attr_reader :buffer

    def initialize
      @cycles = 0
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
        self.vcount += 1
        if vcount == 160
          self.vblank = true
          res = true
          dispcnt = read_io16(0)
          case dispcnt & 0x7
          when 0
            if dispcnt[8] == 0
              @buffer.fill(@palram[0] | (@palram[1] << 8)) # BG0 off: only the backdrop is left
            else
              bg0cnt = read_io16(8)
              char_base = bg0cnt[2..3] << 14
              map_base  = bg0cnt[8..12] << 11
              160.times do |y|
                240.times do |x|
                  tile_map_index = map_base + ((((y >> 3) << 5) + (x >> 3)) << 1)
                  tile_map = @vram[tile_map_index] | (@vram[tile_map_index + 1] << 8)
                  palette_index = tile_map >> 12
                  tile_index = tile_map & 0x03FF
                  pixel_index = char_base + (tile_index << 5) + ((y & 7) << 2) + ((x & 7) >> 1)
                  pixel = @vram[pixel_index]
                  color = x[0] == 0 ? (pixel & 0x0F) : (pixel >> 4)
                  i = color == 0 ? 0 : ((palette_index << 4) + color) << 1
                  @buffer[y * 240 + x] = @palram[i] | (@palram[i + 1] << 8)
                end
              end
            end
          when 3
            (160 * 240).times do |i|
              @buffer[i] = @vram[i << 1] | (@vram[(i << 1) + 1] << 8)
            end
          when 4
            start_address = dispcnt[4] == 0 ? 0 : 0xA000
            (160 * 240).times do |i|
              palette_offset = @vram[start_address + i] << 1
              @buffer[i] = @palram[palette_offset] | (@palram[palette_offset + 1] << 8)
            end
          end
        end

        self.vblank = false if vcount == 227
        self.vcount = 0 if vcount == 228
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
      case offset
      when 4 then @io[4] = (value & ~0b111) | (@io[4] & 0b111) # DISPSTAT bits 0-2 are read-only
      when 6, 7 then nil # VCOUNT is read-only
      else @io[offset] = value
      end
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

    # Decided before mirroring: byte writes to the 0x06018000- mirror are ignored
    def bg_vram?(addr)
      (addr & 0x1FFFF) < (read_io16(0) & 0x7 >= 3 ? 0x14000 : 0x10000)
    end

    private

    def vcount
      @io[6]
    end

    def vcount=(value)
      @io[6] = value
    end

    def vblank=(value)
      @io[4] = value ? @io[4] | 1 : @io[4] & ~1
    end

    def vram_index(addr)
      addr[16] == 0 ? addr & 0xFFFF : addr & 0x17FFF
    end
  end
end
