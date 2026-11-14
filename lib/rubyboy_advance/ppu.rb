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
      update_vcount_match # line 0 already matches LYC 0
      @top_layers = Array.new(240, 0)
      @second_layers = Array.new(240, 0)
      @second_colors = Array.new(240, 0)
      @window_masks = Array.new(240, 0x3F)
      @window_v_flags = [false, false] # whether WIN0 and WIN1 cover the current line
      @affine_refs = [[0, 0], [0, 0]] # where the left end of the line looks in BG2 and BG3, in 1/256 pixels
      @affine_written = [[false, false], [false, false]] # whether BGnX and BGnY were written since the last line
    end

    def step(cycles)
      res = false
      @cycles += cycles

      while @cycles >= 1007
        unless hblank
          if vcount < 160
            dispcnt = read_io16(0)
            mode = dispcnt & 0x7
            case mode
            when 0, 1, 2
              background = @palram[0] | (@palram[1] << 8)
              @buffer.fill(background, vcount * 240, 240)
              @top_layers.fill(5)
              @second_layers.fill(5)
              @second_colors.fill(background)
              bg_range = case mode
                         when 0 then (0..3)
                         when 1 then (0..2)
                         when 2 then (2..3)
                         end
              bgs = bg_range.select { |n| dispcnt[8 + n] == 1 }
              bgs_by_priority = bgs.group_by { |n| read_io16(8 + n * 2) & 0b11 }
              obj_colors, obj_priorities, obj_alphas, obj_window = dispcnt[12] == 1 ? render_objs(read_objs(vcount), vcount) : [{}, {}, {}, {}]
              update_window_masks(obj_window)
              3.downto(0) do |priority|
                (bgs_by_priority[priority] || []).sort.reverse.each do |n|
                  # BG2 in mode 1 and BG2 and BG3 in mode 2 rotate and scale
                  n >= 2 && mode != 0 ? draw_affine_bg(n, vcount) : draw_bg(n, vcount)
                end
                draw_objs(obj_colors, obj_priorities, priority)
              end
              bldcnt_cache = bldcnt
              bldalpha_cache = bldalpha
              offset = vcount * 240
              effect = ((bldcnt_cache >> 6) & 0b11)
              if effect != 0 || obj_alphas.value?(true)
                evy = [(bldy & 0x1F), 16].min
                eva = [bldalpha_cache & 0x1F, 16].min
                evb = [bldalpha_cache >> 8 & 0x1F, 16].min
                240.times do |x|
                  sfx = @window_masks[x][5] == 1
                  if (@top_layers[x] == 4 && obj_alphas[offset + x] && bldcnt_cache[8 + @second_layers[x]] == 1) || (sfx && effect == 1 && bldcnt_cache[@top_layers[x]] == 1 && bldcnt_cache[8 + @second_layers[x]] == 1)
                    c = @buffer[offset + x]
                    s = @second_colors[x]
                    r = [((c & 0x1F) * eva + (s & 0x1F) * evb) >> 4, 31].min
                    g = [((c >> 5 & 0x1F) * eva + (s >> 5 & 0x1F) * evb) >> 4, 31].min
                    b = [((c >> 10 & 0x1F) * eva + (s >> 10 & 0x1F) * evb) >> 4, 31].min
                  else
                    next unless sfx && bldcnt_cache[@top_layers[x]] == 1

                    c = @buffer[offset + x]
                    r = c & 0x1F
                    g = (c >> 5) & 0x1F
                    b = (c >> 10) & 0x1F
                    case effect
                    when 2
                      r += ((31 - r) * evy >> 4)
                      g += ((31 - g) * evy >> 4)
                      b += ((31 - b) * evy >> 4)
                    when 3
                      r -= (r * evy >> 4)
                      g -= (g * evy >> 4)
                      b -= (b * evy >> 4)
                    end
                  end
                  @buffer[offset + x] = r | (g << 5) | (b << 10)
                end
              end
            when 3
              start = vcount * 240
              to = start + 240
              (start...to).each do |i|
                @buffer[i] = @vram[i << 1] | (@vram[(i << 1) + 1] << 8)
              end
            when 4
              start_address = dispcnt[4] == 0 ? 0 : 0xA000
              start = vcount * 240
              to = start + 240
              (start...to).each do |i|
                palette_offset = @vram[start_address + i] << 1
                @buffer[i] = @palram[palette_offset] | (@palram[palette_offset + 1] << 8)
              end
            end
          end

          advance_affine_refs if vcount < 160

          self.hblank = true
          @interrupt.request(:hblank) if dispstat[4] == 1
          yield :hblank if vcount < 160 # after the flag, so a DMA reading DISPSTAT sees it
        end

        break unless @cycles >= 1232

        self.vcount += 1
        self.vblank = false if vcount == 227
        self.vcount = 0 if vcount == 228
        if vcount == 160
          res = true
          self.vblank = true
          @interrupt.request(:vblank) if dispstat[3] == 1
        end

        self.hblank = false
        update_vcount_match
        update_window_v_flags
        load_affine_refs if vcount < 160
        yield :vblank if vcount == 160 # once DISPSTAT is up to date for line 160

        @cycles -= 1232
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
      # A new LYC takes effect at once, not at the next line (NanoBoyAdvance registers.cc)
      update_vcount_match if offset == 5
      # A new BGnX or BGnY is read in before the next line, not at once (NanoBoyAdvance background.cc)
      @affine_written[(offset - 0x28) >> 4][(offset >> 2) & 1] = true if (0x28..0x2F).cover?(offset) || (0x38..0x3F).cover?(offset)
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

    def update_window_masks(obj_window)
      dispcnt = read_io16(0)
      if dispcnt[13] == 0 && dispcnt[14] == 0 && (dispcnt[15] == 0 || dispcnt[12] == 0)
        @window_masks.fill(0x3F)
        return
      end

      240.times do |x|
        @window_masks[x] = if dispcnt[13] == 1 && in_window?(x, 0)
                             @io[0x48] & 0b111111
                           elsif dispcnt[14] == 1 && in_window?(x, 1)
                             @io[0x49] & 0b111111
                           elsif dispcnt[15] == 1 && obj_window[vcount * 240 + x]
                             @io[0x4B] & 0b111111
                           else
                             @io[0x4A] & 0b111111
                           end
      end
    end

    def in_window?(x, window)
      win_h = read_io16(0x40 + window * 2)
      x1 = (win_h >> 8)
      x2 = (win_h & 0xFF)

      return false unless (x >= x1 && x < x2) || (x2 < x1 && (x >= x1 || x < x2))

      @window_v_flags[window]
    end

    # A window turns on as a line starts at Y1 and off at Y2, VBlank lines too, and stays so in between,
    # so a Y1 or Y2 written later waits for that line (NanoBoyAdvance window.cc InitWindow)
    def update_window_v_flags
      2.times do |n|
        @window_v_flags[n] = true if vcount == @io[0x45 + n * 2] # Y1
        @window_v_flags[n] = false if vcount == @io[0x44 + n * 2] # Y2
      end
    end

    # Rotated and scaled BG2 or BG3: a map of one-byte tile numbers, always 256 colors and no flips
    # (NanoBoyAdvance background.inl)
    def draw_affine_bg(n, y)
      i = n - 2
      bgncnt = read_io16(8 + n * 2)
      size = 128 << (bgncnt >> 14) # 128, 256, 512 or 1024 pixels square
      char_base = bgncnt[2..3] << 14
      map_base = bgncnt[8..12] << 11
      pa = signed16(read_io16(0x20 + i * 0x10))
      pc = signed16(read_io16(0x24 + i * 0x10))
      ref_x, ref_y = @affine_refs[i]
      240.times do |x|
        next if @window_masks[x][n] == 0

        tex_x = (ref_x + pa * x) >> 8
        tex_y = (ref_y + pc * x) >> 8
        if bgncnt[13] == 1 # wraparound
          tex_x &= size - 1
          tex_y &= size - 1
        elsif tex_x < 0 || tex_x >= size || tex_y < 0 || tex_y >= size
          next
        end

        tile = @vram[(map_base + (tex_y >> 3) * (size >> 3) + (tex_x >> 3)) & 0xFFFF] # the map address wraps at 64 KB
        color = @vram[char_base + (tile << 6) + ((tex_y & 7) << 3) + (tex_x & 7)]
        next if color == 0

        @second_layers[x] = @top_layers[x]
        @top_layers[x] = n
        @second_colors[x] = @buffer[y * 240 + x]
        @buffer[y * 240 + x] = @palram[color << 1] | (@palram[(color << 1) + 1] << 8)
      end
    end

    # As a line starts, BG2 and BG3 take their reference points from BGnX and BGnY if it is line 0
    # or if those were written during the line before (NanoBoyAdvance background.cc InitBackground)
    def load_affine_refs
      2.times do |i|
        2.times do |axis| # X and Y each, so the other keeps what PB or PD added (NanoBoyAdvance background.cc)
          next unless vcount == 0 || @affine_written[i][axis]

          @affine_refs[i][axis] = affine_point(0x28 + i * 0x10 + axis * 4)
          @affine_written[i][axis] = false
        end
      end
    end

    # After each line the reference points move by PB and PD, only while that BG is on: BG2 in modes 1-5,
    # BG3 in mode 2 (NanoBoyAdvance background.cc, which says this was checked on hardware)
    def advance_affine_refs
      dispcnt = read_io16(0)
      mode = dispcnt & 0x7
      2.times do |i|
        next unless dispcnt[10 + i] == 1 && (i == 0 ? mode.between?(1, 5) : mode == 2)

        @affine_refs[i][0] += signed16(read_io16(0x22 + i * 0x10))
        @affine_refs[i][1] += signed16(read_io16(0x26 + i * 0x10))
      end
    end

    # BGnX and BGnY: 28-bit signed, 8 bits of them a fraction
    def affine_point(offset)
      value = (read_io16(offset) | (read_io16(offset + 2) << 16)) & 0x0FFF_FFFF
      value[27] == 1 ? value - 0x1000_0000 : value
    end

    def signed16(value) = value[15] == 1 ? value - 0x10000 : value

    def draw_bg(n, y)
      bgncnt = read_io16(8 + n * 2)
      size = bgncnt >> 14 # 0: 256×256, 1: 512×256, 2: 256×512, 3: 512×512
      char_base = bgncnt[2..3] << 14
      map_base  = bgncnt[8..12] << 11
      hofs = read_io16(0x10 + n * 4)
      vofs = read_io16(0x12 + n * 4)
      map_y = (y + vofs) & (size[1] == 0 ? 0xFF : 0x1FF)
      240.times do |x|
        next if @window_masks[x][n] == 0

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

        @second_layers[x] = @top_layers[x]
        @top_layers[x] = n
        @second_colors[x] = @buffer[y * 240 + x]
        @buffer[y * 240 + x] = @palram[i] | (@palram[i + 1] << 8)
      end
    end

    def draw_objs(obj_colors, obj_priorities, priority)
      obj_colors.each do |index, color|
        next unless obj_priorities[index] == priority
        next if @window_masks[index % 240][4] == 0

        x = index % 240
        @second_layers[x] = @top_layers[x]
        @top_layers[x] = 4
        @second_colors[x] = @buffer[index]

        @buffer[index] = color
      end
    end

    # Merges all OBJs into one layer keyed by screen index before it meets the BGs, as the hardware does.
    # In OAM order a pixel goes to a lower priority value, or to any OBJ while it is still transparent.
    # A transparent pixel keeps the color under it but still sets the priority, so it can lift an OBJ
    # with a lower number in front of a BG (NanoBoyAdvance sprite.cc).
    def render_objs(objs, y)
      obj_colors = {}
      obj_priorities = {}
      obj_alphas = {}
      obj_window = {}
      is_1d = read_io16(0)[6] == 1

      objs.each do |obj|
        width, height = OBJ_SIZES[obj[:shape]][obj[:size]]
        box_width, box_height = obj[:double] == 1 ? [width * 2, height * 2] : [width, height]
        bank = obj[:color256] == 0 ? obj[:bank] : 0

        row = (y - obj[:y]) & 0xFF # the line within the box

        if obj[:rotate] == 1
          pa, pb, pc, pd = obj_affine_matrix(obj[:matrix])
          # Where the left end of this line of the box looks in the OBJ, in 1/256 pixels: the box center
          # looks at the OBJ center (NanoBoyAdvance sprite.cc)
          left_x = pb * (row - box_height / 2) - pa * (box_width / 2) + (width << 7)
          left_y = pd * (row - box_height / 2) - pc * (box_width / 2) + (height << 7)
        else
          tex_y = obj[:yflip] == 1 ? height - 1 - row : row
        end
        box_width.times do |x|
          screen_x = (obj[:x] + x) & 0x1FF
          next if screen_x >= 240

          if obj[:rotate] == 1
            tex_x = (left_x + pa * x) >> 8
            tex_y = (left_y + pc * x) >> 8
            # Outside the OBJ is not even a clear pixel, so it leaves the priority alone
            next if tex_x < 0 || tex_x >= width || tex_y < 0 || tex_y >= height
          else
            tex_x = obj[:xflip] == 1 ? width - 1 - x : x
          end

          index = y * 240 + screen_x
          in_front = obj_colors[index].nil? || obj[:priority] < obj_priorities[index]
          next unless in_front || obj[:mode] == 2

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
          # An OBJ in mode 2 puts its pixels in the OBJ window, and its clear pixels still lift the
          # priority like any OBJ's (NanoBoyAdvance sprite.cc)
          if obj[:mode] == 2 && color != 0
            obj_window[index] = true
            next
          end
          next unless in_front

          obj_priorities[index] = obj[:priority]
          next if color == 0

          i = 0x200 + (((bank << 4) + color) << 1)
          obj_colors[index] = @palram[i] | (@palram[i + 1] << 8)
          obj_alphas[index] = obj[:mode] == 1
        end
      end

      [obj_colors, obj_priorities, obj_alphas, obj_window]
    end

    # Each group of OBJ affine parameters sits in attr3 of four OBJs in a row: PA, PB, PC and PD
    def obj_affine_matrix(group)
      4.times.map do |i|
        addr = group * 32 + 6 + i * 8
        signed16(@oam[addr] | (@oam[addr + 1] << 8))
      end
    end

    def read_objs(y)
      128.times.filter_map do |i|
        base = i * 8

        shape = @oam[base + 1] >> 6
        next if shape == 3

        rotate = @oam[base + 1][0]
        invisible = @oam[base + 1][1]
        next if rotate == 0 && invisible == 1

        size = @oam[base + 3] >> 6
        obj_y = @oam[base]

        _, height = OBJ_SIZES[shape][size]
        double = rotate & invisible # attr0 bit 9 doubles the box of a rotating OBJ instead of hiding it
        y_max = (obj_y + (height << double)) & 0xFF
        # A box running past line 255 shows only from line 0 (NanoBoyAdvance sprite.cc)
        next unless (y >= obj_y || y_max < obj_y) && y < y_max

        {
          y: obj_y,
          rotate:,
          double:,
          matrix: (@oam[base + 3] >> 1) & 0x1F, # attr1 bits 9-13, for a rotating OBJ
          mode: (@oam[base + 1] >> 2) & 0b11,
          color256: @oam[base + 1][5],
          shape:,
          x: @oam[base + 2] | (@oam[base + 3][0] << 8),
          xflip: @oam[base + 3][4],
          yflip: @oam[base + 3][5],
          size:,
          tile: @oam[base + 4] | ((@oam[base + 5] & 0b11) << 8),
          priority: (@oam[base + 5] >> 2) & 0b11,
          bank: @oam[base + 5] >> 4
        }
      end
    end

    def dispstat
      read_io16(4)
    end

    def bldcnt
      read_io16(0x50)
    end

    def bldalpha
      read_io16(0x52)
    end

    def bldy
      read_io16(0x54)
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

    def hblank
      @io[4][1] == 1
    end

    def hblank=(value)
      @io[4] = value ? @io[4] | 2 : @io[4] & ~2
    end

    def vcount_match=(value)
      @io[4] = value ? @io[4] | 4 : @io[4] & ~4
    end

    # The interrupt comes only as the flag turns on, whether VCOUNT or LYC changed
    def update_vcount_match
      match = vcount == (dispstat >> 8)
      @interrupt.request(:vcount) if dispstat[5] == 1 && dispstat[2] == 0 && match
      self.vcount_match = match
    end

    def vram_index(addr)
      addr[16] == 0 ? addr & 0xFFFF : addr & 0x17FFF
    end
  end
end
