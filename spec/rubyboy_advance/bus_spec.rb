# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Bus do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:bus) do
    described_class.new(
      [0x78, 0x56, 0x34, 0x12],
      [],
      RubyboyAdvance::Ppu.new(interrupt),
      RubyboyAdvance::Sram.new, interrupt,
      RubyboyAdvance::Timer.new(interrupt),
      RubyboyAdvance::Keypad.new(interrupt)
    )
  end

  {
    'EWRAM' => [0x0200_0000, 0x0204_0000],
    'IWRAM' => [0x0300_0000, 0x0300_8000],
    'I/O' => [0x0400_0000],
    'palette RAM' => [0x0500_0000, 0x0500_0400],
    'OAM' => [0x0700_0000, 0x0700_0400]
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

  describe 'cartridge RAM' do
    it 'reads 0xFF before anything is written' do
      expect(bus.read(0x0E00_0000)).to eq(0xFF)
    end

    it 'mirrors every 64 KB and at 0x0F000000' do
      bus.write(0x0E00_0000, 0xAB)

      expect([0x0E01_0000, 0x0F00_0000].map { bus.read(it) }).to eq([0xAB, 0xAB])
    end

    it 'repeats the byte at the address on 16- and 32-bit reads' do
      bus.write(0x0E00_0003, 0xAB)

      expect(bus.read16(0x0E00_0003)).to eq(0xABAB)
      expect(bus.read32(0x0E00_0003)).to eq(0xABAB_ABAB)
    end

    it 'writes only the byte for the address on 16-bit writes' do
      bus.write16(0x0E00_0000, 0xAABB)
      bus.write16(0x0E00_0011, 0xAABB)

      expect([0x00, 0x01, 0x10, 0x11].map { bus.read(0x0E00_0000 + it) }).to eq([0xBB, 0xFF, 0xFF, 0xAA])
    end

    it 'writes only the byte for the address on 32-bit writes' do
      bus.write32(0x0E00_0002, 0xAABB_CCDD)

      expect([0, 1, 2, 3].map { bus.read(0x0E00_0000 + it) }).to eq([0xFF, 0xFF, 0xBB, 0xFF])
    end
  end

  describe 'EEPROM' do
    def bus_with(rom, cartram)
      described_class.new(
        rom, [], RubyboyAdvance::Ppu.new(interrupt), cartram, interrupt,
        RubyboyAdvance::Timer.new(interrupt), RubyboyAdvance::Keypad.new(interrupt)
      )
    end

    let(:rom) { Array.new(4, 0xAB) }

    it 'takes the 16-bit accesses in the ROM area with address bit 24 set' do
      bus = bus_with(rom, RubyboyAdvance::Eeprom.new)

      expect([0x0900_0000, 0x0B00_0000, 0x0D00_0000].map { bus.read16(it) }).to eq([1, 1, 1])
      expect([bus.read16(0x0800_0000), bus.read16(0x0C00_0000), bus.read(0x0D00_0000)]).to eq([0xABAB, 0xABAB, 0])
    end

    it 'leaves the other areas with address bit 24 set alone' do
      bus = bus_with(rom, RubyboyAdvance::Eeprom.new)

      bus.write16(0x0300_0000, 0x5555)

      expect(bus.read16(0x0300_0000)).to eq(0x5555)
    end

    it 'reads two bits for a 32-bit access' do
      bus = bus_with(rom, RubyboyAdvance::Eeprom.new)

      expect(bus.read32(0x0D00_0000)).to eq(0x0001_0001)
    end

    it 'takes only the last 256 bytes of 0x0D000000 when the ROM is over 16 MB' do
      big_rom = double(size: 0x0100_0001)
      allow(big_rom).to receive(:[]).and_return(0xAB)
      bus = bus_with(big_rom, RubyboyAdvance::Eeprom.new)

      expect([bus.read16(0x0DFF_FEFE), bus.read16(0x0DFF_FF00)]).to eq([0xABAB, 1])
    end

    it 'leaves 0x0D000000 to the ROM on other cartridges' do
      bus = bus_with(rom, RubyboyAdvance::Sram.new)

      expect(bus.read16(0x0D00_0000)).to eq(0)
    end
  end

  describe 'interrupt registers' do
    it 'reads back IE and IME' do
      bus.write16(0x0400_0200, 0x2001)
      bus.write16(0x0400_0208, 1)

      expect([bus.read16(0x0400_0200), bus.read16(0x0400_0208)]).to eq([0x2001, 1])
    end

    it 'keeps only bit 0 of IME' do
      bus.write16(0x0400_0208, 0xFFFF)

      expect(bus.read16(0x0400_0208)).to eq(1)
    end

    it 'clears only the IF bits written as 1, in both bytes' do
      interrupt.instance_variable_set(:@if, 0x2001)

      bus.write16(0x0400_0202, 0x0001)
      expect(bus.read16(0x0400_0202)).to eq(0x2000)

      bus.write16(0x0400_0202, 0x2000)
      expect(bus.read16(0x0400_0202)).to eq(0)
    end
  end

  it 'reads 0xFF from unmapped addresses' do
    expect(bus.read(0x0100_0000)).to eq(0xFF)
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

  describe 'cycles' do
    let(:bus) do
      described_class.new(
        [0] * 4, [0] * 4, RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt,
        RubyboyAdvance::Timer.new(interrupt), RubyboyAdvance::Keypad.new(interrupt)
      )
    end

    def cycles
      bus.take_cycles
      yield
      bus.take_cycles
    end

    {
      'the BIOS' => [0x0000_0000, 1, 1],
      'EWRAM' => [0x0200_0000, 3, 6],
      'IWRAM' => [0x0300_0000, 1, 1],
      'I/O' => [0x0400_0000, 1, 1],
      'palette RAM' => [0x0500_0000, 1, 2],
      'VRAM' => [0x0600_0000, 1, 2],
      'OAM' => [0x0700_0000, 1, 1],
      'the ROM' => [0x0800_0000, 5, 8],
      'the second ROM mirror' => [0x0A00_0000, 5, 10],
      'the last ROM mirror' => [0x0D00_0000, 5, 14],
      'cartridge RAM' => [0x0E00_0000, 5, 5],
      'unused memory' => [0x0100_0000, 1, 1],
      'the top of the address space' => [0xFF00_0000, 1, 1],
      'an address past 32 bits' => [0x1_0000_0000, 1, 1]
    }.each do |name, (addr, cost, cost32)|
      it "counts #{cost} for each 8- and 16-bit access and #{cost32} for each 32-bit one to #{name}, away from the last" do
        reads = [cycles { bus.read(addr) }, cycles { bus.read16(addr) }, cycles { bus.read32(addr) }]
        writes = [cycles { bus.write(addr, 0) }, cycles { bus.write16(addr, 0) }, cycles { bus.write32(addr, 0) }]

        expect([reads, writes]).to eq([[cost, cost, cost32]] * 2)
      end
    end

    it 'adds up the accesses until take_cycles, which starts again from 0' do
      bus.take_cycles
      bus.read16(0x0200_0000)
      bus.write32(0x0800_0000, 0)

      expect([bus.take_cycles, bus.take_cycles]).to eq([11, 0])
    end

    describe 'accesses that follow the last one' do
      {
        'the ROM' => [0x0800_0000, 3, 6],
        'the second ROM mirror' => [0x0A00_0000, 5, 10],
        'the last ROM mirror' => [0x0C00_0000, 9, 18],
        'EWRAM' => [0x0200_0000, 3, 6],
        'cartridge RAM' => [0x0E00_0000, 5, 5]
      }.each do |name, (addr, cost, cost32)|
        it "counts #{cost} for each 8- and 16-bit access and #{cost32} for each 32-bit one to #{name}" do
          bus.write(addr, 0)
          reads = [cycles { bus.read(addr + 1) }, cycles { bus.read16(addr + 2) }, cycles { bus.read32(addr + 4) }]
          writes = [cycles { bus.write32(addr + 8, 0) }, cycles { bus.write16(addr + 12, 0) }, cycles { bus.write(addr + 14, 0) }]

          expect([reads, writes]).to eq([[cost, cost, cost32], [cost32, cost, cost]])
        end
      end

      it 'counts the full cost again after a gap or an access somewhere else' do
        bus.read16(0x0800_0000)
        after_gap = cycles { bus.read16(0x0800_0004) }
        bus.read16(0x0200_0000)
        after_another = cycles { bus.read16(0x0800_0006) }

        expect([after_gap, after_another]).to eq([5, 5])
      end
    end

    describe 'WAITCNT' do
      # 16 bits away from the last access, 16 bits following it, then the same for 32 bits
      def costs(area)
        addr = area << 24
        [cycles { bus.read16(addr) }, cycles { bus.read16(addr + 2) }, cycles { bus.read32(addr) }, cycles { bus.read32(addr + 4) }]
      end

      {
        0x0000 => { 0x08 => [5, 3, 8, 6], 0x0A => [5, 5, 10, 10], 0x0C => [5, 9, 14, 18], 0x0E => [5, 5, 5, 5] },
        0x4317 => { 0x08 => [4, 2, 6, 4], 0x0A => [5, 5, 10, 10], 0x0C => [9, 9, 18, 18], 0x0E => [9, 9, 9, 9] },
        0x06A9 => { 0x08 => [3, 3, 6, 6], 0x0A => [4, 2, 6, 4], 0x0C => [3, 2, 5, 4], 0x0E => [4, 4, 4, 4] },
        0x055E => { 0x08 => [9, 2, 11, 4], 0x0A => [3, 5, 8, 10], 0x0C => [4, 2, 6, 4], 0x0E => [3, 3, 3, 3] }
      }.each do |waitcnt, expected|
        it "sets the costs of the ROM mirrors and the cartridge RAM for #{format('%#06x', waitcnt)}" do
          bus.write16(0x0400_0204, waitcnt)

          expect(expected.keys.to_h { |area| [area, costs(area)] }).to eq(expected)
        end
      end

      it 'gives the second half of each area the same costs as the first' do
        bus.write16(0x0400_0204, 0x06A9)

        expect([0x09, 0x0B, 0x0D, 0x0F].map { costs(it) }).to eq([0x08, 0x0A, 0x0C, 0x0E].map { costs(it) })
      end

      it 'takes a write to either byte alone' do
        bus.write(0x0400_0204, 0x10)
        lower = costs(0x08)
        bus.write(0x0400_0205, 0x07)

        expect([lower, costs(0x08), costs(0x0C)]).to eq([[5, 2, 7, 4], [5, 2, 7, 4], [9, 2, 11, 4]])
      end
    end
  end
end
