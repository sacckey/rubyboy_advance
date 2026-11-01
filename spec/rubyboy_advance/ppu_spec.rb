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
