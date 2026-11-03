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
