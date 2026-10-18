# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Bus do
  let(:bus) { described_class.new([0x78, 0x56, 0x34, 0x12], RubyboyAdvance::Ppu.new) }

  {
    'EWRAM' => [0x0200_0000, 0x0204_0000],
    'IWRAM' => [0x0300_0000, 0x0300_8000],
    'I/O' => [0x0400_0000],
    'palette RAM' => [0x0500_0000, 0x0500_0400],
    'OAM' => [0x0700_0000, 0x0700_0400],
    'cartridge RAM' => [0x0E00_0000]
  }.each do |name, (addr, mirror)|
    describe name do
      it 'reads back a written byte' do
        bus.write(addr, 0xAB)

        expect(bus.read(addr)).to eq(0xAB)
      end

      next unless mirror

      it 'reads the same byte through its mirror' do
        bus.write(addr, 0xAB)

        expect(bus.read(mirror)).to eq(0xAB)
      end
    end
  end

  describe 'VRAM' do
    it 'mirrors the last 32 KB onto the 32 KB before it' do
      bus.write(0x0601_0000, 0xAB)

      expect(bus.read(0x0601_8000)).to eq(0xAB)
    end

    it 'mirrors every 128 KB' do
      bus.write(0x0600_8000, 0xAB)

      expect(bus.read(0x0602_8000)).to eq(0xAB)
    end
  end

  describe 'ROM' do
    it 'reads the ROM bytes' do
      expect(bus.read(0x0800_0003)).to eq(0x12)
    end

    it 'ignores writes' do
      bus.write(0x0800_0000, 0xAB)

      expect(bus.read(0x0800_0000)).to eq(0x78)
    end

    it 'reads 0 past the end of the ROM' do
      expect(bus.read(0x0800_0004)).to eq(0)
    end
  end

  it 'reads 0xFF from unmapped addresses' do
    expect(bus.read(0x0000_0000)).to eq(0xFF)
  end

  describe '16- and 32-bit access' do
    it 'reads little-endian values' do
      expect(bus.read16(0x0800_0000)).to eq(0x5678)
      expect(bus.read32(0x0800_0000)).to eq(0x1234_5678)
    end

    it 'writes little-endian values' do
      bus.write32(0x0200_0000, 0x1234_5678)
      bus.write16(0x0200_0004, 0xABCD)

      expect([0, 1, 2, 3, 4, 5].map { |i| bus.read(0x0200_0000 + i) }).to eq([0x78, 0x56, 0x34, 0x12, 0xCD, 0xAB])
    end
  end
end
