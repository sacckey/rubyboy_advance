# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Dma do
  let(:rom) { [] }
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:ppu) { RubyboyAdvance::Ppu.new(interrupt) }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      rom,
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

  def start(channel, sad, dad, count, control)
    base = 0x0400_00B0 + (channel * 12)
    bus.write32(base, sad)
    bus.write32(base + 4, dad)
    bus.write16(base + 8, count)
    bus.write16(base + 10, control)
  end

  def halfwords(addr, count) = Array.new(count) { |i| bus.read16(addr + (i * 2)) }

  before { 4.times { |i| bus.write16(0x0200_0000 + (i * 2), 0x1111 * (i + 1)) } }

  it 'copies halfwords right away and clears the enable bit' do
    start(0, 0x0200_0000, 0x0300_0000, 3, 0x8000)

    expect(halfwords(0x0300_0000, 4)).to eq([0x1111, 0x2222, 0x3333, 0])
    expect(bus.read16(0x0400_00BA)).to eq(0)
  end

  it 'copies words when bit 10 is set' do
    start(3, 0x0200_0000, 0x0300_0000, 2, 0x8400)

    expect(halfwords(0x0300_0000, 4)).to eq([0x1111, 0x2222, 0x3333, 0x4444])
  end

  it 'keeps the source fixed' do
    start(1, 0x0200_0000, 0x0300_0000, 3, 0x8100)

    expect(halfwords(0x0300_0000, 4)).to eq([0x1111, 0x1111, 0x1111, 0])
  end

  it 'moves the destination backwards' do
    start(2, 0x0200_0000, 0x0300_0004, 3, 0x8020)

    expect(halfwords(0x0300_0000, 3)).to eq([0x3333, 0x2222, 0x1111])
  end

  { 0 => 0x4000, 3 => 0x10000 }.each do |channel, max|
    it "copies #{format('%#x', max)} units for a count of 0 on DMA#{channel}" do
      start(channel, 0x0200_0000, 0x0201_0000, 0, 0x8100)

      expect(halfwords(0x0201_0000 + ((max - 1) * 2), 2)).to eq([0x1111, 0])
    end
  end

  it 'ignores source bits above 28 on DMA3' do
    start(3, 0x1200_0000, 0x0300_0000, 1, 0x8000)

    expect(halfwords(0x0300_0000, 1)).to eq([0x1111])
  end

  it 'ignores destination bits above 27 on DMA0' do
    start(0, 0x0200_0000, 0x0B00_0000, 1, 0x8000)

    expect(halfwords(0x0300_0000, 1)).to eq([0x1111])
  end

  context 'from the Game Pak ROM' do
    let(:rom) { [0x11, 0x11, 0x22, 0x22, 0x33, 0x33] }

    it 'moves the source forwards even when it is set to fixed' do
      start(3, 0x0800_0000, 0x0300_0000, 3, 0x8100)

      expect(halfwords(0x0300_0000, 3)).to eq([0x1111, 0x2222, 0x3333])
    end
  end

  it 'waits for VBlank and keeps the enable bit' do
    start(0, 0x0200_0000, 0x0300_0000, 3, 0x9000)

    expect(halfwords(0x0300_0000, 3)).to eq([0, 0, 0])
    expect(bus.read16(0x0400_00BA)).to eq(0x9000)
  end

  it 'ignores the repeat bit of an immediate transfer' do
    start(0, 0x0200_0000, 0x0300_0000, 1, 0x8200) # immediate, repeat

    expect(bus.read16(0x0400_00BA)).to eq(0x0200)
  end

  describe 'at VBlank and HBlank' do
    let(:table) { 0x0200_1000 }

    before { 161.times { |i| bus.write16(table + (i * 2), i + 1) } } # entry i is i + 1

    it 'copies as VBlank starts and clears the enable bit without repeat' do
      start(0, 0x0200_0000, 0x0300_0000, 3, 0x9000) # VBlank
      step(1232 * 160 - 1)
      expect(halfwords(0x0300_0000, 1)).to eq([0])

      step(1)

      expect(halfwords(0x0300_0000, 4)).to eq([0x1111, 0x2222, 0x3333, 0])
      expect(bus.read16(0x0400_00BA)).to eq(0x1000)
    end

    it 'copies at the HBlank of each visible line, going on from where it stopped' do
      start(0, table, 0x0300_0000, 1, 0xA200) # HBlank, repeat
      step(1007)
      expect(halfwords(0x0300_0000, 2)).to eq([1, 0])

      step(1232 * 228 - 1007)

      expect(halfwords(0x0300_0000 + (159 * 2), 2)).to eq([160, 0]) # lines 0-159 only, none in VBlank
    end

    it 'puts the destination back for each repeat with destination control 3' do
      start(3, table, 0x0300_0000, 1, 0xA260) # HBlank, repeat, destination reload

      step(1232 + 1007) # through the HBlank of line 1

      expect(halfwords(0x0300_0000, 2)).to eq([2, 0])
    end

    it 'copies at one HBlank only and clears the enable bit without repeat' do
      start(0, table, 0x0300_0000, 1, 0xA000) # HBlank

      step(1232 * 228)

      expect(halfwords(0x0300_0000, 2)).to eq([1, 0])
      expect(bus.read16(0x0400_00BA)).to eq(0x2000)
    end

    it 'keeps going when CNT_H is written again with the enable bit still on' do
      start(0, table, 0x0300_0000, 1, 0xA260) # HBlank, repeat, destination reload
      step(1232) # line 0 copies entry 0
      bus.write16(0x0400_00BA, 0xA260)

      step(1007)

      expect(halfwords(0x0300_0000, 1)).to eq([2]) # entry 1, not entry 0 again
    end

    it 'keeps the count it was enabled with when CNT_L changes while it waits' do
      start(0, 0x0200_0000, 0x0300_0000, 1, 0x9000) # VBlank, count 1
      bus.write16(0x0400_00B8, 3) # CNT_L 3

      step(1232 * 160)

      expect(halfwords(0x0300_0000, 2)).to eq([0x1111, 0])
    end

    it 'reads CNT_L again as each repeat finishes' do
      start(0, table, 0x0300_0000, 1, 0xA200) # HBlank, repeat, count 1
      step(1007) # line 0 copies entry 0 and takes count 1 again
      bus.write16(0x0400_00B8, 2) # CNT_L 2

      step(1232 * 2) # line 1 still copies 1, line 2 copies 2

      expect(halfwords(0x0300_0000, 5)).to eq([1, 2, 3, 4, 0])
    end

    it 'runs at HBlank after the HBlank flag turns on' do
      start(0, 0x0400_0004, 0x0300_0000, 1, 0xA100) # HBlank, source fixed: DISPSTAT

      step(1007)

      expect(bus.read16(0x0300_0000)[1]).to eq(1)
    end

    it 'runs at VBlank after DISPSTAT is updated for line 160' do
      bus.write16(0x0400_0004, 160 << 8) # LYC 160
      start(0, 0x0400_0004, 0x0300_0000, 1, 0x9100) # VBlank, source fixed: DISPSTAT

      step(1232 * 160)

      expect(bus.read16(0x0300_0000) & 0b111).to eq(0b101) # VBlank on, HBlank off, VCOUNT match on
    end

    it 'runs DMA0 before DMA1 at the same HBlank' do
      start(1, table, 0x0300_0000, 1, 0xA000) # HBlank: entry 0
      start(0, table + 2, 0x0300_0000, 1, 0xA000) # HBlank: entry 1

      step(1007)

      expect(halfwords(0x0300_0000, 1)).to eq([1]) # DMA1 wrote last
    end
  end
end
