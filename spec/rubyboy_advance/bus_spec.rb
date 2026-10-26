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
      it 'reads back a written halfword' do
        bus.write16(addr, 0xABCD)

        expect(bus.read16(addr)).to eq(0xABCD)
      end

      next unless mirror

      it 'reads the same halfword through its mirror' do
        bus.write16(addr, 0xABCD)

        expect(bus.read16(mirror)).to eq(0xABCD)
      end
    end
  end

  describe 'VRAM' do
    it 'mirrors the last 32 KB onto the 32 KB before it' do
      bus.write16(0x0601_0000, 0xABCD)

      expect(bus.read16(0x0601_8000)).to eq(0xABCD)
    end

    it 'mirrors every 128 KB' do
      bus.write16(0x0600_8000, 0xABCD)

      expect(bus.read16(0x0602_8000)).to eq(0xABCD)
    end
  end

  describe 'byte writes to video memory' do
    it 'ignores OAM' do
      bus.write(0x0700_0010, 0xAB)

      expect(bus.read16(0x0700_0010)).to eq(0)
    end

    it 'writes the byte to both halves of a palette halfword' do
      bus.write(0x0500_0021, 0xAB)

      expect(bus.read16(0x0500_0020)).to eq(0xABAB)
    end

    context 'in tiled modes' do
      it 'writes the byte to both halves of a BG VRAM halfword' do
        bus.write(0x0600_FFFF, 0xAB)

        expect(bus.read16(0x0600_FFFE)).to eq(0xABAB)
      end

      it 'ignores OBJ VRAM from 0x06010000' do
        bus.write(0x0601_0000, 0xAB)

        expect(bus.read16(0x0601_0000)).to eq(0)
      end
    end

    context 'in bitmap modes' do
      before { bus.write16(0x0400_0000, 3) }

      it 'treats VRAM up to 0x06013FFF as BG' do
        bus.write(0x0601_3FFF, 0xAB)

        expect(bus.read16(0x0601_3FFE)).to eq(0xABAB)
      end

      it 'ignores OBJ VRAM from 0x06014000' do
        bus.write(0x0601_4000, 0xAB)

        expect(bus.read16(0x0601_4000)).to eq(0)
      end

      it 'ignores the mirror of BG VRAM at 0x06018000' do
        bus.write16(0x0601_0000, 0x1234)
        bus.write(0x0601_8001, 0xAB)

        expect(bus.read16(0x0601_0000)).to eq(0x1234)
      end
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

    it 'mirrors the ROM at 0x0A000000 and 0x0C000000' do
      expect(bus.read(0x0A00_0003)).to eq(0x12)
      expect(bus.read(0x0C00_0003)).to eq(0x12)
    end

    it 'maps 32 MB at each mirror' do
      expect([0x0900_0000, 0x0B00_0000, 0x0D00_0000].map { bus.read(it) }).to eq([0, 0, 0])
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

    it 'ignores the low two bits of 32-bit addresses' do
      bus.write32(0x0200_0003, 0x1234_5678)

      expect(bus.read32(0x0200_0000)).to eq(0x1234_5678)
      expect(bus.read32(0x0200_0002)).to eq(0x1234_5678)
      expect(bus.read(0x0200_0004)).to eq(0)
    end

    it 'ignores the low bit of 16-bit addresses' do
      bus.write16(0x0200_0001, 0xABCD)

      expect(bus.read16(0x0200_0000)).to eq(0xABCD)
      expect(bus.read16(0x0200_0001)).to eq(0xABCD)
      expect(bus.read(0x0200_0002)).to eq(0)
    end
  end
end
