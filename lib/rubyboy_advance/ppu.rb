# frozen_string_literal: true

module RubyboyAdvance
  class Ppu
    attr_reader :buffer

    OBJ_SIZES = [ # [shape][size] = [width, height]
      [[8, 8], [16, 16], [32, 32], [64, 64]],
      [[16, 8], [32, 8], [32, 16], [64, 32]],
      [[8, 16], [8, 32], [16, 32], [32, 64]]
    ].freeze

    def initialize(interrupt)
      @cycles = 0
      @io = Array.new(0x60, 0)
      @palram = Array.new(0x400, 0)
      @vram = Array.new(0x18000, 0)
      @oam = Array.new(0x400, 0)
      @buffer = Array.new(240 * 160, 0x7FFF)
      @interrupt = interrupt
    end

    def step(cycles)
      res = false
      @cycles += cycles

      while @cycles >= 1232
        @cycles -= 1232
        self.vcount += 1
        if vcount == 160
          self.vblank = true
          @interrupt.request(:vblank) if dispstat[3] == 1
          res = true
          dispcnt = read_io16(0)
          case dispcnt & 0x7
          when 0
            @buffer.fill(@palram[0] | (@palram[1] << 8))
            bgs = (0..3).select { |n| dispcnt[8 + n] == 1 }
            bgs_by_priority = bgs.group_by { |n| read_io16(8 + n * 2) & 0b11 }
            obj_colors, obj_priorities = dispcnt[12] == 1 ? render_objs(read_objs) : [{}, {}]
            3.downto(0) do |priority|
              (bgs_by_priority[priority] || []).sort.reverse.each do |n|
                draw_bg(n)
              end
              draw_objs(obj_colors, obj_priorities, priority)
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

    def draw_bg(n)
      bgncnt = read_io16(8 + n * 2)
      size = bgncnt >> 14 # 0: 256×256, 1: 512×256, 2: 256×512, 3: 512×512
      char_base = bgncnt[2..3] << 14
      map_base  = bgncnt[8..12] << 11
      hofs = read_io16(0x10 + n * 4)
      vofs = read_io16(0x12 + n * 4)
      160.times do |y|
        map_y = (y + vofs) & (size[1] == 0 ? 0xFF : 0x1FF)
        240.times do |x|
          map_x = (x + hofs) & (size[0] == 0 ? 0xFF : 0x1FF)
          block = (map_x >> 8) + (map_y >> 8) * (size[0] == 0 ? 1 : 2)
          tile_map_index = map_base + (block << 11) + (((((map_y & 0xFF) >> 3) << 5) + ((map_x & 0xFF) >> 3)) << 1)
          tile_map = @vram[tile_map_index] | (@vram[tile_map_index + 1] << 8)
          tile_y = tile_map[11] == 1 ? 7 - (map_y & 7) : map_y & 7
          tile_x = tile_map[10] == 1 ? 7 - (map_x & 7) : map_x & 7
          palette_index = tile_map >> 12
          tile_index = tile_map & 0x03FF
          if bgncnt[7] == 0
            pixel_index = char_base + (tile_index << 5) + (tile_y << 2) + (tile_x >> 1)
            pixel = @vram[pixel_index]
            color = tile_x[0] == 0 ? (pixel & 0x0F) : (pixel >> 4)
          else
            palette_index = 0
            pixel_index = char_base + (tile_index << 6) + (tile_y << 3) + tile_x
            color = pixel_index >= 0x10000 ? 0 : @vram[pixel_index]
          end

          next if color == 0

          i = ((palette_index << 4) + color) << 1
          @buffer[y * 240 + x] = @palram[i] | (@palram[i + 1] << 8)
        end
      end
    end

    def draw_objs(obj_colors, obj_priorities, priority)
      obj_colors.each do |index, color|
        @buffer[index] = color if obj_priorities[index] == priority
      end
    end

    # Merges all OBJs into one layer keyed by screen index before it meets the BGs, as the hardware does.
    # In OAM order a pixel goes to a lower priority value, or to any OBJ while it is still transparent.
    # A transparent pixel keeps the color under it but still sets the priority, so it can lift an OBJ
    # with a lower number in front of a BG (NanoBoyAdvance sprite.cc).
    def render_objs(objs)
      obj_colors = {}
      obj_priorities = {}
      is_1d = read_io16(0)[6] == 1

      objs.each do |obj|
        next if obj[:rotate] == 0 && obj[:invisible] == 1
        next if obj[:shape] == 3

        width, height = OBJ_SIZES[obj[:shape]][obj[:size]]
        bank = obj[:color256] == 0 ? obj[:bank] : 0

        height.times do |y|
          screen_y = (obj[:y] + y) & 0xFF
          next if screen_y >= 160

          tex_y = obj[:rotate] == 0 && obj[:yflip] == 1 ? height - 1 - y : y

          width.times do |x|
            screen_x = (obj[:x] + x) & 0x1FF
            next if screen_x >= 240

            tex_x = obj[:rotate] == 0 && obj[:xflip] == 1 ? width - 1 - x : x

            index = screen_y * 240 + screen_x
            next unless obj_colors[index].nil? || obj[:priority] < obj_priorities[index]

            if obj[:color256] == 0
              tile_number = if is_1d
                              (obj[:tile] + (tex_y >> 3) * (width >> 3) + (tex_x >> 3)) & 0x3FF
                            else
                              ((obj[:tile] + ((tex_y >> 3) << 5)) & 0x3E0) | ((obj[:tile] + (tex_x >> 3)) & 0x1F)
                            end

              pixel = @vram[0x10000 + (tile_number << 5) + ((tex_y & 7) << 2) + ((tex_x & 7) >> 1)]
              color = tex_x[0] == 0 ? (pixel & 0x0F) : (pixel >> 4)
            else
              tile_number = if is_1d
                              (obj[:tile] + (tex_y >> 3) * (width >> 2) + ((tex_x >> 3) << 1)) & 0x3FF
                            else
                              ((obj[:tile] + ((tex_y >> 3) << 5)) & 0x3E0) | (((obj[:tile] & ~1) + ((tex_x >> 3) << 1)) & 0x1F)
                            end

              # Tile 1023 runs past the end of VRAM, so the address wraps within the OBJ tiles (mGBA software-obj.c)
              color = @vram[0x10000 + (((tile_number << 5) + ((tex_y & 7) << 3) + (tex_x & 7)) & 0x7FFF)]
            end
            obj_priorities[index] = obj[:priority]
            next if color == 0

            i = 0x200 + (((bank << 4) + color) << 1)
            obj_colors[index] = @palram[i] | (@palram[i + 1] << 8)
          end
        end
      end

      [obj_colors, obj_priorities]
    end

    def read_objs
      128.times.map do |i|
        base = i * 8
        {
          y: @oam[base],
          rotate: @oam[base + 1][0],
          invisible: @oam[base + 1][1],
          color256: @oam[base + 1][5],
          shape: @oam[base + 1] >> 6,
          x: @oam[base + 2] | (@oam[base + 3][0] << 8),
          xflip: @oam[base + 3][4],
          yflip: @oam[base + 3][5],
          size: @oam[base + 3] >> 6,
          tile: @oam[base + 4] | ((@oam[base + 5] & 0b11) << 8),
          priority: (@oam[base + 5] >> 2) & 0b11,
          bank: @oam[base + 5] >> 4
        }
      end
    end

    def dispstat
      read_io16(4)
    end

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
