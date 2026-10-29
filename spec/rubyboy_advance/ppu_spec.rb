# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Ppu do
  let(:ppu) { described_class.new }
  let(:bus) { RubyboyAdvance::Bus.new([], ppu, RubyboyAdvance::Sram.new) }

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
  end
end
