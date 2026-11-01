# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Dma do
  let(:rom) { [] }
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:bus) { RubyboyAdvance::Bus.new(rom, [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt, RubyboyAdvance::Timer.new(interrupt)) }

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
end
