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

  describe 'mode 0' do
    it 'draws BG0 with the tile palette bank and shows the backdrop for color 0' do
      bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
      bus.write16(0x0400_0008, 0x0100) # BG0CNT: tiles at 0x06000000, map at 0x06000800
      bus.write16(0x0600_0800, 0x1000) # map entry (0, 0): tile 0, palette bank 1
      bus.write16(0x0600_0000, 0x0010) # tile 0 row 0: x = 0 is color 0, x = 1 is color 1
      bus.write16(0x0500_0000, 0x1111) # backdrop
      bus.write16(0x0500_0020, 0x2222) # bank 1 color 0
      bus.write16(0x0500_0022, 0x3333) # bank 1 color 1

      ppu.step(1232 * 160)

      expect(ppu.buffer[0, 2]).to eq([0x1111, 0x3333])
    end

    it 'fills the screen with the backdrop once BG0 is turned off' do
      bus.write16(0x0400_0000, 0x0100) # DISPCNT: mode 0, BG0 on
      bus.write16(0x0400_0008, 0x0100) # BG0CNT: tiles at 0x06000000, map at 0x06000800
      bus.write16(0x0600_0000, 0x0001) # tile 0 row 0: x = 0 is color 1
      bus.write16(0x0500_0000, 0x1111) # backdrop
      bus.write16(0x0500_0002, 0x3333) # bank 0 color 1
      ppu.step(1232 * 160)

      bus.write16(0x0400_0000, 0x0000) # BG0 off

      expect { ppu.step(1232 * 228) }.to change { ppu.buffer[0] }.from(0x3333).to(0x1111)
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

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 3]).to eq([0x3333, 0x4444, 0x1111])
      end

      it 'puts the BG with the lower priority value in front' do
        bus.write16(0x0400_0000, 0x0300) # DISPCNT: mode 0, BG0 and BG1 on
        bus.write16(0x0400_0008, 0x0101) # BG0CNT: priority 1, map at 0x06000800
        bus.write16(0x0400_000A, 0x0200) # BG1CNT: priority 0, map at 0x06001000

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 3]).to eq([0x4444, 0x4444, 0x1111])
      end

      it 'draws only the BGs DISPCNT turns on' do
        bus.write16(0x0400_0000, 0x0200) # DISPCNT: mode 0, BG1 on
        bus.write16(0x0400_0008, 0x0100) # BG0CNT: priority 0, map at 0x06000800
        bus.write16(0x0400_000A, 0x0200) # BG1CNT: priority 0, map at 0x06001000

        ppu.step(1232 * 160)

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

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 2]).to eq([4, 5]) # map (3, 2) and (4, 2)
        expect(ppu.buffer[240]).to eq(0x1111) # map (3, 3): row 3 of tile 0 is color 0
      end

      it 'wraps around the edges of the map' do
        bus.write16(0x0600_0800, 0x0001) # map entry (0, 0): tile 1; every other entry is the empty tile 0
        8.times { |row| bus.write32(0x0600_0020 + row * 4, 0x1111_1111) } # tile 1: all color 1
        bus.write16(0x0400_0010, 252) # BG0HOFS
        bus.write16(0x0400_0012, 255) # BG0VOFS

        ppu.step(1232 * 160)

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

          ppu.step(1232 * 160)

          expect(ppu.buffer[0]).to eq(block + 1) # tile block + 1 is all color block + 1
        end
      end
    end

    describe 'OBJ' do
      def write_obj(index, attr0, attr1, attr2)
        bus.write16(0x0700_0000 + index * 8, attr0)
        bus.write16(0x0700_0002 + index * 8, attr1)
        bus.write16(0x0700_0004 + index * 8, attr2)
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

        ppu.step(1232 * 160)

        expect(ppu.buffer[240 + 1, 10]).to eq([0x7FFF] + [0x3333] * 8 + [0x7FFF])
        expect(ppu.buffer[2]).to eq(0x7FFF) # row 0 is above the OBJ
        expect(ppu.buffer[240 * 9 + 2]).to eq(0x7FFF) # row 9 is below it
      end

      it 'draws no OBJ while DISPCNT bit 12 is off' do
        bus.write16(0x0400_0000, 0x0000) # DISPCNT: mode 0, OBJ off
        write_obj(0, 0, 0, 1) # y 0, x 0, tile 1

        ppu.step(1232 * 160)

        expect(ppu.buffer[0]).to eq(0x7FFF)
      end

      it 'puts the lower OBJ number in front and shows what is behind through color 0' do
        write_obj(0, 0, 0, 3) # y 0, x 0, tile 3
        write_obj(1, 0, 0, 2) # y 0, x 0, tile 2

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 8]).to eq([0x2222] * 4 + [0x1111] * 4)
      end

      it 'draws OBJs over the BGs' do
        bus.write16(0x0400_0000, 0x1100) # DISPCNT: mode 0, BG0 and OBJ on
        bus.write16(0x0400_0008, 0x0004) # BG0CNT: tiles at 0x06004000, map at 0x06000000 (every entry tile 0)
        bus.write32(0x0600_4000, 0x1111_1111) # BG tile 0 row 0: all color 1
        bus.write16(0x0500_0002, 0x4444) # BG bank 0 color 1
        write_obj(0, 0, 0, 3) # y 0, x 0, tile 3

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 9]).to eq([0x4444] * 4 + [0x1111] * 4 + [0x4444])
      end

      it 'hides an OBJ with attr0 bit 9 only while bit 8 is clear' do
        write_obj(0, 0x0200, 0, 1) # bit 9 alone: hidden
        write_obj(1, 0x0300, 8, 1) # bits 8 and 9: an affine OBJ, drawn as a plain one for now

        ppu.step(1232 * 160)

        expect([ppu.buffer[0], ppu.buffer[8]]).to eq([0x7FFF, 0x1111])
      end

      it 'wraps an OBJ past the bottom and right edges to the top and left' do
        write_obj(0, 252, 508, 1) # 4 pixels above the top and left of the left edge
        write_obj(1, 8, 300, 1) # x 300 is off the right edge, not 300 - 256 = 44

        ppu.step(1232 * 160)

        expect(ppu.buffer[0, 5]).to eq([0x1111] * 4 + [0x7FFF])
        expect([ppu.buffer[240 * 3], ppu.buffer[240 * 4]]).to eq([0x1111, 0x7FFF])
        expect(ppu.buffer[240 * 8 + 44]).to eq(0x7FFF)
      end
    end
  end

  describe 'VBlank interrupt' do
    it 'is requested only when DISPSTAT bit 3 is set' do
      ppu.step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(0)

      bus.write16(0x0400_0004, 0x0008) # DISPSTAT: VBlank IRQ on
      ppu.step(1232 * 228)
      expect(bus.read16(0x0400_0202)).to eq(1)
    end
  end
end
