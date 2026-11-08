# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Ppu do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:ppu) { described_class.new(interrupt) }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      [],
      [],
      ppu,
      RubyboyAdvance::Sram.new,
      interrupt,
      RubyboyAdvance::Timer.new(interrupt),
      RubyboyAdvance::Keypad.new(interrupt)
    )
  end

  # Steps the PPU as exe does, running DMA at each HBlank and VBlank it yields
  def step(cycles) = ppu.step(cycles) { |timing| bus.run_dma(timing) }

  describe 'mode 0' do
    it 'draws BG0 with the tile palette bank and shows the backdrop for color 0' do
      bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
      bus.write16(0x0400_0008, 0x0100) # BG0CNT: tiles at 0x06000000, map at 0x06000800
      bus.write16(0x0600_0800, 0x1000) # map entry (0, 0): tile 0, palette bank 1
      bus.write16(0x0600_0000, 0x0010) # tile 0 row 0: x = 0 is color 0, x = 1 is color 1
      bus.write16(0x0500_0000, 0x1111) # backdrop
      bus.write16(0x0500_0020, 0x2222) # bank 1 color 0
      bus.write16(0x0500_0022, 0x3333) # bank 1 color 1

      step(1232 * 160)

      expect(ppu.buffer[0, 2]).to eq([0x1111, 0x3333])
    end

    it 'fills the screen with the backdrop once BG0 is turned off' do
      bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
      bus.write16(0x0400_0008, 0x0100) # BG0CNT: tiles at 0x06000000, map at 0x06000800
      bus.write16(0x0600_0000, 0x0001) # tile 0 row 0: x = 0 is color 1
      bus.write16(0x0500_0000, 0x1111) # backdrop
      bus.write16(0x0500_0002, 0x3333) # bank 0 color 1
      step(1232 * 160)

      bus.write16(0x0400_0000, 0x0000) # BG0 off

      expect { step(1232 * 228) }.to change { ppu.buffer[0] }.from(0x3333).to(0x1111)
    end

    describe 'with BG0 and BG1' do
      before do
        bus.write16(0x0600_0800, 0x0001) # BG0 map entry (0, 0): tile 1
        bus.write16(0x0600_1000, 0x0002) # BG1 map entry (0, 0): tile 2
        bus.write16(0x0600_0020, 0x0001) # tile 1 row 0: x = 0 is color 1, x = 1 and 2 are color 0
        bus.write16(0x0600_0040, 0x0022) # tile 2 row 0: x = 0 and 1 are color 2, x = 2 is color 0
        bus.write16(0x0500_0000, 0x1111) # backdrop
        bus.write16(0x0500_0002, 0x3333) # bank 0 color 1
        bus.write16(0x0500_0004, 0x4444) # bank 0 color 2
      end

      it 'puts the lower BG number in front when the priorities are equal' do
        bus.write16(0x0400_0000, 0x0300) # DISPCNT: mode 0, BG0 and BG1 on
        bus.write16(0x0400_0008, 0x0100) # BG0CNT: priority 0, map at 0x06000800
        bus.write16(0x0400_000A, 0x0200) # BG1CNT: priority 0, map at 0x06001000

        step(1232 * 160)

        expect(ppu.buffer[0, 3]).to eq([0x3333, 0x4444, 0x1111])
      end

      it 'puts the BG with the lower priority value in front' do
        bus.write16(0x0400_0000, 0x0300) # DISPCNT: mode 0, BG0 and BG1 on
        bus.write16(0x0400_0008, 0x0101) # BG0CNT: priority 1, map at 0x06000800
        bus.write16(0x0400_000A, 0x0200) # BG1CNT: priority 0, map at 0x06001000

        step(1232 * 160)

        expect(ppu.buffer[0, 3]).to eq([0x4444, 0x4444, 0x1111])
      end

      it 'draws only the BGs DISPCNT turns on' do
        bus.write16(0x0400_0000, 0x0200) # DISPCNT: mode 0, BG1 on
        bus.write16(0x0400_0008, 0x0100) # BG0CNT: priority 0, map at 0x06000800
        bus.write16(0x0400_000A, 0x0200) # BG1CNT: priority 0, map at 0x06001000

        step(1232 * 160)

        expect(ppu.buffer[0, 3]).to eq([0x4444, 0x4444, 0x1111])
      end
    end

    describe 'scrolling' do
      before do
        bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
        bus.write16(0x0400_0008, 0x0100) # BG0CNT: 256x256, tiles at 0x06000000, map at 0x06000800
        bus.write16(0x0500_0000, 0x1111) # backdrop
        8.times { |color| bus.write16(0x0500_0002 + color * 2, color + 1) } # bank 0 color c reads as c
      end

      it 'moves the screen by BG0HOFS and BG0VOFS pixels, inside a tile too' do
        bus.write32(0x0600_0008, 0x8765_4321) # tile 0 row 2: column c is color c + 1; every map entry is tile 0
        bus.write16(0x0400_0010, 3) # BG0HOFS
        bus.write16(0x0400_0012, 2) # BG0VOFS

        step(1232 * 160)

        expect(ppu.buffer[0, 2]).to eq([4, 5]) # map (3, 2) and (4, 2)
        expect(ppu.buffer[240]).to eq(0x1111) # map (3, 3): row 3 of tile 0 is color 0
      end

      it 'wraps around the edges of the map' do
        bus.write16(0x0600_0800, 0x0001) # map entry (0, 0): tile 1; every other entry is the empty tile 0
        8.times { |row| bus.write32(0x0600_0020 + row * 4, 0x1111_1111) } # tile 1: all color 1
        bus.write16(0x0400_0010, 252) # BG0HOFS
        bus.write16(0x0400_0012, 255) # BG0VOFS

        step(1232 * 160)

        expect(ppu.buffer[240 + 3, 2]).to eq([0x1111, 1]) # map (255, 0) and (0, 0)
        expect(ppu.buffer[4]).to eq(0x1111) # map (0, 255)
      end
    end

    describe 'map sizes' do
      before do
        bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
        4.times do |block|
          bus.write16(0x0600_4000 + block * 0x800, block + 1) # top-left entry of each 32x32-tile block: tile block + 1
          8.times { |row| bus.write32(0x0600_0000 + ((block + 1) << 5) + row * 4, 0x1111_1111 * (block + 1)) }
          bus.write16(0x0500_0002 + block * 2, block + 1) # bank 0 color c reads as c
        end
      end

      [
        [0, 256, 0, 0], [0, 0, 256, 0],
        [1, 256, 0, 1], [1, 0, 256, 0],
        [2, 256, 0, 0], [2, 0, 256, 1],
        [3, 256, 0, 1], [3, 0, 256, 2], [3, 256, 256, 3]
      ].each do |size, hofs, vofs, block|
        it "shows block #{block} at map (#{hofs}, #{vofs}) when BG0CNT size is #{size}" do
          bus.write16(0x0400_0008, (size << 14) | (8 << 8)) # BG0CNT: tiles at 0x06000000, map at 0x06004000
          bus.write16(0x0400_0010, hofs) # BG0HOFS
          bus.write16(0x0400_0012, vofs) # BG0VOFS

          step(1232 * 160)

          expect(ppu.buffer[0]).to eq(block + 1) # tile block + 1 is all color block + 1
        end
      end
    end

    describe 'tile flips' do
      # [y, x] of every pixel drawn inside the 8x8 block of map entry (0, 0)
      def drawn
        8.times.flat_map { |y| 8.times.filter_map { |x| [y, x] if ppu.buffer[y * 240 + x] != 0x1111 } }
      end

      before do
        bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
        bus.write16(0x0400_0008, 0x0104) # BG0CNT: tiles at 0x06004000, map at 0x06000800
        bus.write16(0x0600_4020, 0x0001) # tile 1: color 1 at row 0, column 0 only
        bus.write16(0x0600_4040, 0x0002) # tile 2: color 2 at row 0, column 0 only
        bus.write16(0x0500_0000, 0x1111) # backdrop
        bus.write16(0x0500_0002, 0x3333) # bank 0 color 1
        bus.write16(0x0500_0004, 0x4444) # bank 0 color 2
      end

      {
        'no flip' => [0x0001, [0, 0]],
        'a horizontal flip (bit 10)' => [0x0401, [0, 7]],
        'a vertical flip (bit 11)' => [0x0801, [7, 0]],
        'both flips' => [0x0C01, [7, 7]]
      }.each do |flip, (entry, pixel)|
        it "moves the pixel of the tile to #{pixel.inspect} with #{flip}" do
          bus.write16(0x0600_0800, entry) # map entry (0, 0): tile 1

          step(1232 * 160)

          expect(drawn).to eq([pixel])
        end
      end

      it 'keeps the flip bits out of the tile number' do
        bus.write16(0x0600_0800, 0x0402) # map entry (0, 0): tile 2, horizontal flip

        step(1232 * 160)

        expect(ppu.buffer[7]).to eq(0x4444)
      end
    end

    describe '256 colors' do
      before do
        bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
        bus.write16(0x0400_0008, 0x0180) # BG0CNT: 256 colors, tiles at 0x06000000, map at 0x06000800
        256.times { |color| bus.write16(0x0500_0000 + color * 2, color) } # color c reads as c
        bus.write16(0x0500_0000, 0x7FFF) # backdrop
      end

      it 'reads a byte per pixel from 64-byte tiles and ignores the palette bank' do
        bus.write16(0x0600_0800, 0x1001) # map entry (0, 0): tile 1, palette bank 1
        bus.write32(0x0600_0040, 0x0023_0021) # tile 1 row 0: x = 0 is color 0x21, x = 1 is 0, x = 2 is 0x23
        bus.write16(0x0600_0048, 0x0081) # tile 1 row 1: x = 0 is color 0x81
        bus.write16(0x0600_007E, 0xFF00) # tile 1 row 7: x = 7 is color 0xFF

        step(1232 * 160)

        expect([ppu.buffer[0, 3], ppu.buffer[240], ppu.buffer[240 * 7 + 7]]).to eq([[0x21, 0x7FFF, 0x23], 0x81, 0xFF])
      end

      it 'flips a tile by whole pixels' do
        bus.write16(0x0600_0800, 0x0C01) # map entry (0, 0): tile 1, both flips
        bus.write16(0x0600_0040, 0x2100) # tile 1 row 0: x = 1 is color 0x21

        step(1232 * 160)

        expect(ppu.buffer[240 * 7 + 6]).to eq(0x21)
      end

      it 'shows nothing for tile bytes at or past 0x06010000, where the OBJ tiles start' do
        bus.write16(0x0400_0008, 0x018C) # BG0CNT: 256 colors, tiles at 0x0600C000, map at 0x06000800
        bus.write16(0x0600_0800, 0x00FF) # map entry (0, 0): tile 255, the last one before 0x06010000
        bus.write16(0x0600_0802, 0x0100) # map entry (1, 0): tile 256, at 0x06010000
        bus.write16(0x0600_0804, 0x03FF) # map entry (2, 0): tile 1023, past the end of VRAM
        bus.write16(0x0600_FFC0, 0x0021) # tile 255 row 0: x = 0 is color 0x21
        bus.write16(0x0601_0000, 0x0021) # OBJ tile 0: the first byte is 0x21 too

        step(1232 * 160)

        expect([ppu.buffer[0], ppu.buffer[8], ppu.buffer[16]]).to eq([0x21, 0x7FFF, 0x7FFF])
      end
    end

    describe 'OBJ' do
      def write_obj(index, attr0, attr1, attr2)
        bus.write16(0x0700_0000 + index * 8, attr0)
        bus.write16(0x0700_0002 + index * 8, attr1)
        bus.write16(0x0700_0004 + index * 8, attr2)
      end

      # The color at the top-left pixel of each 8x8 block of the screen, row by row
      def blocks(columns, rows)
        rows.times.map { |row| columns.times.map { |column| ppu.buffer[row * 8 * 240 + column * 8] } }
      end

      before do
        bus.write16(0x0400_0000, 0x1000) # DISPCNT: mode 0, OBJ on
        bus.write16(0x0500_0000, 0x7FFF) # backdrop
        bus.write16(0x0500_0202, 0x1111) # OBJ bank 0 color 1
        bus.write16(0x0500_0204, 0x2222) # OBJ bank 0 color 2
        8.times do |row|
          bus.write32(0x0601_0020 + row * 4, 0x1111_1111) # OBJ tile 1: all color 1
          bus.write32(0x0601_0040 + row * 4, 0x2222_2222) # OBJ tile 2: all color 2
          bus.write32(0x0601_0060 + row * 4, 0x1111_0000) # OBJ tile 3: x = 0-3 color 0, x = 4-7 color 1
        end
        128.times { |index| write_obj(index, 0x0200, 0, 0) } # attr0 bit 9: hidden
      end

      it 'draws an 8x8 OBJ from the OBJ tiles with its OBJ palette bank' do
        8.times { |row| bus.write32(0x0601_2020 + row * 4, 0x2222_2222) } # OBJ tile 0x101: all color 2
        bus.write16(0x0500_0224, 0x3333) # OBJ bank 1 color 2
        write_obj(0, 1, 2, 0x1101) # y 1, x 2, tile 0x101, bank 1

        step(1232 * 160)

        expect(ppu.buffer[240 + 1, 10]).to eq([0x7FFF] + [0x3333] * 8 + [0x7FFF])
        expect(ppu.buffer[2]).to eq(0x7FFF) # row 0 is above the OBJ
        expect(ppu.buffer[240 * 9 + 2]).to eq(0x7FFF) # row 9 is below it
      end

      it 'draws no OBJ while DISPCNT bit 12 is off' do
        bus.write16(0x0400_0000, 0x0000) # DISPCNT: mode 0, OBJ off
        write_obj(0, 0, 0, 1) # y 0, x 0, tile 1

        step(1232 * 160)

        expect(ppu.buffer[0]).to eq(0x7FFF)
      end

      it 'puts the lower OBJ number in front and shows what is behind through color 0' do
        write_obj(0, 0, 0, 3) # y 0, x 0, tile 3
        write_obj(1, 0, 0, 2) # y 0, x 0, tile 2

        step(1232 * 160)

        expect(ppu.buffer[0, 8]).to eq([0x2222] * 4 + [0x1111] * 4)
      end

      it 'draws OBJs over the BGs' do
        bus.write16(0x0400_0000, 0x1100) # DISPCNT: mode 0, BG0 and OBJ on
        bus.write16(0x0400_0008, 0x0004) # BG0CNT: tiles at 0x06004000, map at 0x06000000 (every entry tile 0)
        bus.write32(0x0600_4000, 0x1111_1111) # BG tile 0 row 0: all color 1
        bus.write16(0x0500_0002, 0x4444) # BG bank 0 color 1
        write_obj(0, 0, 0, 3) # y 0, x 0, tile 3

        step(1232 * 160)

        expect(ppu.buffer[0, 9]).to eq([0x4444] * 4 + [0x1111] * 4 + [0x4444])
      end

      it 'hides an OBJ with attr0 bit 9 only while bit 8 is clear' do
        write_obj(0, 0x0200, 0, 1) # bit 9 alone: hidden
        write_obj(1, 0x0300, 8, 1) # bits 8 and 9: an affine OBJ, drawn as a plain one for now

        step(1232 * 160)

        expect([ppu.buffer[0], ppu.buffer[8]]).to eq([0x7FFF, 0x1111])
      end

      it 'wraps an OBJ past the bottom and right edges to the top and left' do
        write_obj(0, 252, 508, 1) # 4 pixels above the top and left of the left edge
        write_obj(1, 8, 300, 1) # x 300 is off the right edge, not 300 - 256 = 44

        step(1232 * 160)

        expect(ppu.buffer[0, 5]).to eq([0x1111] * 4 + [0x7FFF])
        expect([ppu.buffer[240 * 3], ppu.buffer[240 * 4]]).to eq([0x1111, 0x7FFF])
        expect(ppu.buffer[240 * 8 + 44]).to eq(0x7FFF)
      end

      describe 'sizes' do
        before do
          # Only row 0 of these tiles is colored and every other tile is empty,
          # so reading a wrong tile or a wrong row shows the backdrop or a different color
          {
            0 => 10, 1 => 1, 2 => 2, 3 => 3, 4 => 4, 5 => 12, 6 => 13, 7 => 14, 8 => 15,
            31 => 5, 32 => 11, 33 => 6, 34 => 7, 63 => 8, 1023 => 9
          }.each { |tile, color| bus.write32(0x0601_0000 + tile * 32, 0x1111_1111 * color) }
          16.times { |color| bus.write16(0x0500_0200 + color * 2, color) } # OBJ bank 0 color c reads as c
        end

        [
          [0, 0, 8, 8], [0, 1, 16, 16], [0, 2, 32, 32], [0, 3, 64, 64],
          [1, 0, 16, 8], [1, 1, 32, 8], [1, 2, 32, 16], [1, 3, 64, 32],
          [2, 0, 8, 16], [2, 1, 8, 32], [2, 2, 16, 32], [2, 3, 32, 64]
        ].each do |shape, size, width, height|
          it "is #{width}x#{height} for shape #{shape} and size #{size}" do
            64.times { |tile| 8.times { |row| bus.write32(0x0601_0000 + tile * 32 + row * 4, 0x1111_1111) } }
            bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
            write_obj(0, shape << 14, size << 14, 0) # y 0, x 0, tile 0

            step(1232 * 160)

            drawn = (0...(240 * 160)).reject { |i| ppu.buffer[i] == 0x7FFF }
            expect([drawn.map { |i| i % 240 }.max + 1, drawn.map { |i| i / 240 }.max + 1]).to eq([width, height])
          end
        end

        it 'skips shape 3' do
          write_obj(0, 0xC000, 0, 1) # shape 3, tile 1

          step(1232 * 160)

          expect(blocks(1, 1)).to eq([[0x7FFF]])
        end

        it 'takes the tiles of each row one after another in 1D mapping' do
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
          write_obj(0, 0x4000, 0x8000, 1) # 32x16, tile 1

          step(1232 * 160)

          expect(blocks(5, 3)).to eq([[1, 2, 3, 4, 0x7FFF], [12, 13, 14, 15, 0x7FFF], [0x7FFF] * 5]) # tiles 1-4 / 5-8
        end

        it 'takes the next row of tiles 32 tiles later in 2D mapping' do
          write_obj(0, 0, 0x4000, 1) # 16x16, tile 1

          step(1232 * 160)

          expect(blocks(3, 3)).to eq([[1, 2, 0x7FFF], [6, 7, 0x7FFF], [0x7FFF] * 3]) # tiles 1, 2 / 33, 34
        end

        it 'wraps the tile number at 1024 in 1D mapping' do
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
          write_obj(0, 0, 0x4000, 1023) # 16x16, tile 1023

          step(1232 * 160)

          expect(blocks(2, 2)).to eq([[9, 10], [1, 2]]) # tiles 1023, 0 / 1, 2
        end

        it 'wraps within a row of 32 tiles in 2D mapping' do
          write_obj(0, 0, 0x4000, 31) # 16x16, tile 31

          step(1232 * 160)

          expect(blocks(2, 2)).to eq([[5, 10], [8, 11]]) # tiles 31, 0 / 63, 32
        end
      end

      describe 'priority' do
        def enable_bg0(priority)
          bus.write16(0x0400_0000, 0x1100) # DISPCNT: mode 0, BG0 and OBJ on
          bus.write16(0x0400_0008, 0x0004 | priority) # BG0CNT: tiles at 0x06004000, map at 0x06000000 (every entry tile 0)
        end

        before do
          bus.write32(0x0600_4000, 0x1111_1111) # BG tile 0 row 0: all color 1
          bus.write16(0x0500_0002, 0x4444) # BG bank 0 color 1
        end

        [[1, 1, 0x1111], [1, 2, 0x4444], [2, 1, 0x1111]].each do |bg_priority, obj_priority, color|
          it "shows #{color == 0x1111 ? 'the OBJ' : 'BG0'} when BG0 has priority #{bg_priority} and the OBJ #{obj_priority}" do
            enable_bg0(bg_priority)
            write_obj(0, 0, 0, 1 | (obj_priority << 10)) # y 0, x 0, tile 1

            step(1232 * 160)

            expect(ppu.buffer[0]).to eq(color)
          end
        end

        it 'draws OBJs at a priority no BG uses' do
          write_obj(0, 0, 0, 1 | (3 << 10)) # y 0, x 0, tile 1, priority 3; no BG is on

          step(1232 * 160)

          expect(ppu.buffer[0]).to eq(0x1111)
        end

        it 'puts the OBJ with the lower priority value in front, whatever its OBJ number' do
          write_obj(0, 0, 0, 1 | (2 << 10)) # y 0, x 0, tile 1, priority 2
          write_obj(1, 0, 0, 2 | (1 << 10)) # y 0, x 0, tile 2, priority 1

          step(1232 * 160)

          expect(ppu.buffer[0]).to eq(0x2222)
        end

        it 'puts a BG between OBJs of different priorities' do
          enable_bg0(1)
          bus.write32(0x0600_4000, 0x1111_0000) # BG tile 0 row 0: x = 0-3 color 0, x = 4-7 color 1
          write_obj(0, 0, 0, 2 | (2 << 10)) # y 0, x 0, tile 2, priority 2: behind BG0
          write_obj(1, 0, 6, 1) # y 0, x 6, tile 1, priority 0: in front of BG0

          step(1232 * 160)

          expect(ppu.buffer[0, 8]).to eq([0x2222] * 4 + [0x4444] * 2 + [0x1111] * 2)
        end

        it 'lifts an OBJ in front of a BG where a later transparent OBJ with a lower priority value covers it' do
          enable_bg0(1)
          write_obj(0, 0, 0, 1 | (2 << 10)) # y 0, x 0, tile 1, priority 2: behind BG0
          write_obj(1, 0, 4, 0) # y 0, x 4, tile 0 (all color 0), priority 0

          step(1232 * 160)

          expect(ppu.buffer[0, 8]).to eq([0x4444] * 4 + [0x1111] * 4) # OBJ 0 keeps its color at priority 0 under OBJ 1
        end

        it 'gives a pixel a transparent OBJ left to a later opaque OBJ at that OBJ priority' do
          enable_bg0(1)
          bus.write32(0x0600_4000, 0x1111_0000) # BG tile 0 row 0: x = 0-3 color 0, x = 4-7 color 1
          write_obj(0, 0, 0, 0) # y 0, x 0, tile 0 (all color 0), priority 0
          write_obj(1, 0, 0, 1 | (2 << 10)) # y 0, x 0, tile 1, priority 2

          step(1232 * 160)

          expect(ppu.buffer[0, 8]).to eq([0x1111] * 4 + [0x4444] * 4) # OBJ 1 is drawn, and stays behind BG0
        end
      end

      describe 'flips' do
        let(:none) { 0x7FFF } # the backdrop: nothing is drawn there

        # The colors at rows 0, 7, 8 and 15 and columns 0, 7, 8 and 15: the corners of the four 8x8 blocks of a 16x16 OBJ
        def corners
          [0, 7, 8, 15].map { |y| [0, 7, 8, 15].map { |x| ppu.buffer[y * 240 + x] } }
        end

        before do
          # Each tile has its color at row 0, column 0 only, so a flip moves it to another corner of its block
          { 1 => 1, 2 => 2, 3 => 3, 4 => 4, 33 => 5, 34 => 6 }.each do |tile, color|
            8.times { |row| bus.write32(0x0601_0000 + tile * 32 + row * 4, row.zero? ? color : 0) }
          end
          16.times { |color| bus.write16(0x0500_0200 + color * 2, color) } # OBJ bank 0 color c reads as c
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
        end

        it 'mirrors the whole OBJ left to right with attr1 bit 12' do
          write_obj(0, 0, 0x5000, 1) # 16x16, horizontal flip, tile 1

          step(1232 * 160)

          expect(corners).to eq([[none, 2, none, 1], [none] * 4, [none, 4, none, 3], [none] * 4])
        end

        it 'mirrors the whole OBJ top to bottom with attr1 bit 13' do
          write_obj(0, 0, 0x6000, 1) # 16x16, vertical flip, tile 1

          step(1232 * 160)

          expect(corners).to eq([[none] * 4, [3, none, 4, none], [none] * 4, [1, none, 2, none]])
        end

        it 'flips which tiles 2D mapping takes too' do
          bus.write16(0x0400_0000, 0x1000) # DISPCNT: mode 0, OBJ on, 2D mapping
          write_obj(0, 0, 0x7000, 1) # 16x16, both flips, tile 1: tiles 1, 2 / 33, 34

          step(1232 * 160)

          expect(corners).to eq([[none] * 4, [none, 6, none, 5], [none] * 4, [none, 2, none, 1]])
        end

        it 'ignores bits 12 and 13 on an affine OBJ' do
          write_obj(0, 0x0100, 0x7000, 1) # affine, 16x16, tile 1; bits 12 and 13 belong to the affine parameter number

          step(1232 * 160)

          expect(corners).to eq([[1, none, 2, none], [none] * 4, [3, none, 4, none], [none] * 4])
        end
      end

      describe '256 colors' do
        before do
          0x20.times { |i| bus.write32(0x0601_0000 + i * 4, 0) } # clears OBJ tiles 0-3
          256.times { |color| bus.write16(0x0500_0200 + color * 2, color) } # OBJ color c reads as c
        end

        it 'reads a byte per pixel from 64 bytes, two tile numbers, and ignores the palette bank' do
          bus.write32(0x0601_0080, 0x0023_0021) # tile 4 row 0: x = 0 is color 0x21, x = 1 is 0, x = 2 is 0x23
          bus.write16(0x0601_0088, 0x0081) # row 1: x = 0 is color 0x81
          bus.write16(0x0601_00BE, 0xFF00) # row 7, in tile 5: x = 7 is color 0xFF
          write_obj(0, 0x2000, 0, 0x1004) # y 0, x 0, 256 colors, tile 4, bank 1

          step(1232 * 160)

          expect([ppu.buffer[0, 3], ppu.buffer[240], ppu.buffer[240 * 7 + 7]]).to eq([[0x21, 0x7FFF, 0x23], 0x81, 0xFF])
        end

        it 'steps two tile numbers per block in 1D mapping' do
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
          { 3 => 1, 5 => 2, 7 => 3, 9 => 4 }.each { |tile, color| bus.write16(0x0601_0000 + tile * 32, color) }
          write_obj(0, 0x2000, 0x4000, 3) # 256 colors, 16x16, tile 3

          step(1232 * 160)

          expect(blocks(2, 2)).to eq([[1, 2], [3, 4]]) # tiles 3, 5 / 7, 9
        end

        it 'wraps the tile number at 1024 in 1D mapping' do
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
          { 1022 => 1, 0 => 2 }.each { |tile, color| bus.write16(0x0601_0000 + tile * 32, color) }
          write_obj(0, 0xA000, 0, 1022) # 256 colors, 8x16, tile 1022

          step(1232 * 160)

          expect(blocks(1, 2)).to eq([[1], [2]]) # tiles 1022 / 0
        end

        it 'wraps past the end of the OBJ tiles to the start of them' do
          bus.write16(0x0400_0000, 0x1040) # DISPCNT: mode 0, OBJ on, 1D mapping
          bus.write16(0x0601_7FE0, 0x0001) # tile 1023 row 0: x = 0 is color 1
          bus.write16(0x0601_0000, 0x0002) # tile 0: the first byte is color 2
          write_obj(0, 0x2000, 0, 1023) # 256 colors, 8x8, tile 1023

          step(1232 * 160)

          expect([ppu.buffer[0], ppu.buffer[240 * 4]]).to eq([1, 2]) # row 4 is at 0x06018000, which wraps to tile 0
        end

        it 'starts from an even tile number and wraps within a row of 32 tiles in 2D mapping' do
          { 30 => 1, 0 => 2, 62 => 3, 32 => 4 }.each { |tile, color| bus.write16(0x0601_0000 + tile * 32, color) }
          write_obj(0, 0x2000, 0x4000, 31) # 256 colors, 16x16, tile 31

          step(1232 * 160)

          expect(blocks(2, 2)).to eq([[1, 2], [3, 4]]) # tiles 30, 0 / 62, 32
        end
      end
    end

    describe 'color effects' do
      def rgb(red, green, blue) = red | (green << 5) | (blue << 10)

      # Line 0 shows BG2 at x = 0, the backdrop at x = 8 and an OBJ over BG2 at x = 16
      def pixels = [ppu.buffer[0], ppu.buffer[8], ppu.buffer[16]]

      def show(bldcnt, bldy = 0, bldalpha: 0, obj_attr0: 0, obj_priority: 0, obj_tile: 1)
        bus.write16(0x0400_0050, bldcnt)
        bus.write16(0x0400_0052, bldalpha)
        bus.write16(0x0400_0054, bldy)
        bus.write16(0x0700_0000, obj_attr0) # OBJ 0: y 0, 8x8
        bus.write16(0x0700_0002, 16) # x 16
        bus.write16(0x0700_0004, obj_tile | (obj_priority << 10))
        step(1232 * 160)
      end

      before do
        bus.write16(0x0400_0000, 0x1400) # DISPCNT: mode 0, BG2 and OBJ on
        bus.write16(0x0400_000C, 0x0004) # BG2CNT: priority 0, tiles at 0x06004000, map at 0x06000000
        bus.write16(0x0600_0002, 0x0001) # map entry (1, 0): tile 1, which is empty
        bus.write32(0x0600_4000, 0x1111_1111) # BG tile 0 row 0: all color 1
        8.times { |row| bus.write32(0x0601_0020 + row * 4, 0x1111_1111) } # OBJ tile 1: all color 1
        bus.write32(0x0601_0060, 0x1111_1111) # OBJ tile 3 row 0: all color 1, the other rows empty
        (1...128).each { |index| bus.write16(0x0700_0000 + index * 8, 0x0200) } # the other OBJs hidden
        bus.write16(0x0500_0000, rgb(31, 0, 16)) # backdrop
        bus.write16(0x0500_0002, rgb(8, 16, 24)) # BG bank 0 color 1
        bus.write16(0x0500_0202, rgb(0, 24, 8)) # OBJ bank 0 color 1
      end

      it 'darkens the 1st targets in BLDCNT bits 0-5 with effect 3 by BLDY / 16' do
        show(0x00C4, 8) # BG2, effect 3

        expect(pixels).to eq([rgb(4, 8, 12), rgb(31, 0, 16), rgb(0, 24, 8)])
      end

      it 'brightens them with effect 2 by BLDY / 16 of the way to white' do
        show(0x0084, 8) # BG2, effect 2

        expect(pixels).to eq([rgb(19, 23, 27), rgb(31, 0, 16), rgb(0, 24, 8)])
      end

      it 'takes the OBJs as bit 4' do
        show(0x00D0, 8) # OBJ, effect 3

        expect(pixels).to eq([rgb(8, 16, 24), rgb(31, 0, 16), rgb(0, 12, 4)])
      end

      it 'takes the backdrop as bit 5' do
        show(0x00E0, 8) # backdrop, effect 3

        expect(pixels).to eq([rgb(8, 16, 24), rgb(16, 0, 8), rgb(0, 24, 8)])
      end

      it 'looks only at the layer in front, so an OBJ behind BG2 leaves the pixel alone' do
        show(0x00D0, 8, obj_priority: 1) # OBJ, effect 3; BG2 has priority 0

        expect(pixels).to eq([rgb(8, 16, 24), rgb(31, 0, 16), rgb(8, 16, 24)])
      end

      it 'treats BLDY above 16 as 16' do
        show(0x0084, 31) # BG2, effect 2

        expect(pixels[0]).to eq(rgb(31, 31, 31))
      end

      [[0x0004, 'effect 0'], [0x0044, 'effect 1 and no 2nd targets in bits 8-13']].each do |bldcnt, setting|
        it "leaves the colors alone with #{setting}" do
          show(bldcnt, 8) # BG2 as the 1st target

          expect(pixels).to eq([rgb(8, 16, 24), rgb(31, 0, 16), rgb(0, 24, 8)])
        end
      end

      it 'mixes each 1st target with the 2nd target right under it with effect 1, by EVA / 16 and EVB / 16' do
        show(0x2454, bldalpha: 0x080C) # 1st BG2 and OBJ, 2nd BG2 and backdrop, effect 1; EVA 12, EVB 8

        expect(pixels).to eq([rgb(21, 12, 26), rgb(31, 0, 16), rgb(4, 26, 18)]) # BG2 over the backdrop, OBJ over BG2
      end

      it 'does not mix when the layer right under is not a 2nd target, even if one further down is' do
        show(0x2050, bldalpha: 0x080C) # 1st OBJ, 2nd backdrop, effect 1; BG2 is between them

        expect(pixels[2]).to eq(rgb(0, 24, 8))
      end

      it 'stops each mixed channel at 31' do
        show(0x2044, bldalpha: 0x1010) # 1st BG2, 2nd backdrop, effect 1; EVA 16, EVB 16

        expect(pixels[0]).to eq(rgb(31, 16, 31))
      end

      [[0x001F, 'only BG2', [8, 16, 24]], [0x1F00, 'only the backdrop', [31, 0, 16]]].each do |bldalpha, shown, color|
        it "treats EVA and EVB above 16 as 16, so BLDALPHA #{format('%04X', bldalpha)} shows #{shown}" do
          show(0x2044, bldalpha:) # 1st BG2, 2nd backdrop, effect 1

          expect(pixels[0]).to eq(rgb(*color))
        end
      end

      it 'brightens rather than mixes with effect 2, even with a 2nd target right under' do
        show(0x2084, 8, bldalpha: 0x080C) # 1st BG2, 2nd backdrop, effect 2

        expect(pixels[0]).to eq(rgb(19, 23, 27))
      end

      it 'mixes a backdrop pixel with the backdrop under it, not with what was under that pixel on the line before' do
        # Line 0 has BG2 over the OBJ at x = 16; on line 1 both are empty there
        show(0x2060, bldalpha: 0x0C0C, obj_priority: 1, obj_tile: 3) # 1st and 2nd backdrop, effect 1; EVA 12, EVB 12

        expect(ppu.buffer[240 + 16]).to eq(rgb(31, 0, 24))
      end

      describe 'with a semi-transparent OBJ' do
        let(:semi) { 0x0400 } # attr0 bits 10-11: 1

        it 'mixes it with the 2nd target under it, even with effect 0 and BLDCNT bit 4 off' do
          show(0x2404, bldalpha: 0x080C, obj_attr0: semi) # 1st BG2, 2nd BG2 and backdrop, effect 0

          expect(pixels).to eq([rgb(8, 16, 24), rgb(31, 0, 16), rgb(4, 26, 18)]) # BG2 over the backdrop stays
        end

        it 'treats it as a normal OBJ when the layer under is not a 2nd target' do
          show(0x00D0, 8, bldalpha: 0x080C, obj_attr0: semi) # 1st OBJ, no 2nd targets, effect 3

          expect(pixels[2]).to eq(rgb(0, 12, 4))
        end

        it 'does not mix it while it is behind BG2' do
          show(0x1400, bldalpha: 0x080C, obj_attr0: semi, obj_priority: 1) # 2nd BG2 and OBJ, effect 0

          expect(pixels[2]).to eq(rgb(8, 16, 24))
        end

        it 'does not mix the pixels a later OBJ in OAM takes from it' do
          bus.write16(0x0700_0008, 0) # OBJ 1: y 0, 8x8, not semi-transparent
          bus.write16(0x0700_000A, 16) # x 16
          bus.write16(0x0700_000C, 1) # tile 1, priority 0, ahead of OBJ 0
          show(0x0400, bldalpha: 0x080C, obj_attr0: semi, obj_priority: 1) # 2nd BG2, effect 0

          expect(pixels[2]).to eq(rgb(0, 24, 8))
        end
      end
    end
  end

  describe 'lines' do
    it 'draws a line once, when its HBlank starts at cycle 1007' do
      bus.write16(0x0500_0000, 0x1111) # backdrop
      step(1006)
      expect(ppu.buffer[0]).to eq(0x7FFF) # not drawn yet

      step(1)
      expect(ppu.buffer[0]).to eq(0x1111)

      bus.write16(0x0500_0000, 0x2222) # the backdrop changes during the HBlank of line 0
      step(1232 * 160 - 1007)
      expect([ppu.buffer[239], ppu.buffer[240], ppu.buffer[240 * 160 - 1]]).to eq([0x1111, 0x2222, 0x2222])
    end

    it 'reads the BG scroll again for each line' do
      bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
      bus.write16(0x0400_0008, 0x0100) # BG0CNT: tiles at 0x06000000, map at 0x06000800
      8.times { |row| bus.write32(0x0600_0000 + row * 4, 0x0000_0001) } # tile 0: x = 0 is color 1
      bus.write16(0x0500_0000, 0x1111) # backdrop
      bus.write16(0x0500_0002, 0x3333) # bank 0 color 1
      step(1007)

      bus.write16(0x0400_0010, 1) # BG0HOFS after line 0 is drawn
      step(1232 * 160 - 1007)

      expect([ppu.buffer[0], ppu.buffer[240], ppu.buffer[240 + 7]]).to eq([0x3333, 0x1111, 0x3333])
    end

    it 'copies each line of the mode 3 bitmap' do
      bus.write16(0x0400_0000, 0x0003) # DISPCNT: mode 3
      bus.write16(0x0600_0000 + (240 + 2) * 2, 0x1234) # pixel (2, 1)

      step(1232 * 160)

      expect(ppu.buffer[240 + 2]).to eq(0x1234)
    end

    it 'copies each line of the mode 4 bitmap from the frame DISPCNT bit 4 picks' do
      bus.write16(0x0400_0000, 0x0014) # DISPCNT: mode 4, frame 1 at 0x0600A000
      bus.write16(0x0600_A000 + 240 + 2, 0x0003) # pixel (2, 1): color 3
      bus.write16(0x0500_0006, 0x1234) # color 3

      step(1232 * 160)

      expect(ppu.buffer[240 + 2]).to eq(0x1234)
    end

    it 'draws nothing in the 68 lines of VBlank' do
      bus.write16(0x0400_0000, 0x1F00) # DISPCNT: mode 0, BG0-3 and OBJ on

      step(1232 * 228)

      expect(ppu.buffer.size).to eq(240 * 160)
    end

    it 'returns true from step once a frame, as VBlank starts' do
      expect([step(1232 * 160 - 1), step(1), step(1232 * 68)]).to eq([false, true, false])
    end

    it 'yields :hblank after each visible line and :vblank as VBlank starts, for DMA' do
      events = []
      ppu.step(1006) { |timing| events << timing }
      expect(events).to eq([])
      ppu.step(1) { |timing| events << [timing, ppu.read_io(6), bus.read16(0x0400_0004)[1]] }
      expect(events).to eq([[:hblank, 0, 1]]) # line 0, with the HBlank flag already on
      events.clear
      ppu.step(1232 * 228 - 1007) { |timing| events << timing }
      expect(events).to eq([:hblank] * 159 + [:vblank]) # none in the 68 lines of VBlank
    end
  end

  describe 'DISPSTAT' do
    def dispstat
      bus.read16(0x0400_0004)
    end

    it 'sets the HBlank flag from cycle 1007 to the end of every line, VBlank lines too' do
      step(1006)
      expect(dispstat[1]).to eq(0)
      step(1)
      expect(dispstat[1]).to eq(1)
      step(224)
      expect(dispstat[1]).to eq(1) # cycle 1231
      step(1)
      expect(dispstat[1]).to eq(0) # line 1

      step(1232 * 199 + 1007)
      expect(dispstat[1]).to eq(1) # line 200, cycle 1007
    end

    it 'sets the VBlank flag from line 160 to line 226' do
      step(1232 * 160 - 1)
      expect(dispstat[0]).to eq(0)
      step(1)
      expect(dispstat[0]).to eq(1) # line 160
      step(1232 * 67 - 1)
      expect(dispstat[0]).to eq(1) # the last cycle of line 226
      step(1)
      expect(dispstat[0]).to eq(0) # line 227
    end

    it 'sets the VCOUNT match flag while VCOUNT equals bits 8-15' do
      bus.write16(0x0400_0004, 5 << 8) # LYC 5
      step(1232 * 5 - 1)
      expect(dispstat[2]).to eq(0) # line 4
      step(1)
      expect(dispstat[2]).to eq(1) # line 5
      step(1232)
      expect(dispstat[2]).to eq(0) # line 6
    end

    it 'updates the VCOUNT match flag as soon as bits 8-15 change' do
      bus.write16(0x0400_0004, 5 << 8) # LYC 5
      step(1232 * 5) # line 5

      bus.write16(0x0400_0004, 6 << 8) # LYC 6
      expect(dispstat[2]).to eq(0)
      bus.write16(0x0400_0004, 5 << 8) # LYC 5
      expect(dispstat[2]).to eq(1)
    end

    it 'starts with the VCOUNT match flag on, since line 0 matches LYC 0' do
      bus.write16(0x0400_0004, 0x0020) # DISPSTAT: VCOUNT IRQ on

      expect([dispstat[2], bus.read16(0x0400_0202)]).to eq([1, 0])
    end

    it 'counts VCOUNT from 227 back to 0 and matches line 0' do
      step(1232 * 227)
      expect(bus.read16(0x0400_0006)).to eq(227)

      step(1232) # LYC 0
      expect([bus.read16(0x0400_0006), dispstat[2]]).to eq([0, 1])
    end
  end

  describe 'VBlank interrupt' do
    it 'is requested only when DISPSTAT bit 3 is set' do
      step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(0)

      bus.write16(0x0400_0004, 0x0008) # DISPSTAT: VBlank IRQ on
      step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(1)
    end
  end

  describe 'HBlank interrupt' do
    it 'is requested at cycle 1007 only when DISPSTAT bit 4 is set' do
      step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(0)

      bus.write16(0x0400_0004, 0x0010) # DISPSTAT: HBlank IRQ on
      step(1006)
      expect(bus.read16(0x0400_0202)).to eq(0)
      step(1)
      expect(bus.read16(0x0400_0202)).to eq(2)
    end

    it 'is requested in VBlank too' do
      bus.write16(0x0400_0004, 0x0010) # DISPSTAT: HBlank IRQ on
      step(1232 * 200)
      bus.write16(0x0400_0202, 0x0002) # clears IF bit 1, left by lines 0-199

      step(1007)

      expect(bus.read16(0x0400_0202)).to eq(2) # line 200
    end
  end

  describe 'VCOUNT interrupt' do
    it 'is requested as VCOUNT reaches bits 8-15 only when DISPSTAT bit 5 is set' do
      bus.write16(0x0400_0004, 5 << 8) # LYC 5
      step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(0)

      bus.write16(0x0400_0004, (5 << 8) | 0x0020) # DISPSTAT: VCOUNT IRQ on, LYC 5
      step(1232 * 5 - 1)
      expect(bus.read16(0x0400_0202)).to eq(0)
      step(1)
      expect(bus.read16(0x0400_0202)).to eq(4)
    end

    it 'is requested again on the next line when the handler moves bits 8-15 there' do
      bus.write16(0x0400_0004, (5 << 8) | 0x0020) # DISPSTAT: VCOUNT IRQ on, LYC 5
      step(1232 * 5) # line 5
      bus.write16(0x0400_0202, 0x0004) # the handler clears IF bit 2
      bus.write16(0x0400_0004, (6 << 8) | 0x0020) # and sets LYC 6

      step(1232) # line 6

      expect(bus.read16(0x0400_0202)).to eq(4)
    end

    it 'is requested at once when bits 8-15 are set to the current line' do
      bus.write16(0x0400_0004, 0x0020) # DISPSTAT: VCOUNT IRQ on, LYC 0
      step(1232 * 5) # line 5

      bus.write16(0x0400_0004, (5 << 8) | 0x0020) # LYC 5

      expect(bus.read16(0x0400_0202)).to eq(4)
    end

    it 'is not requested when bit 5 is turned on during a line that already matches' do
      bus.write16(0x0400_0004, 5 << 8) # LYC 5
      step(1232 * 5) # line 5: the flag is already on

      bus.write16(0x0400_0004, (5 << 8) | 0x0020) # DISPSTAT: VCOUNT IRQ on

      expect(bus.read16(0x0400_0202)).to eq(0)
    end
  end
end
