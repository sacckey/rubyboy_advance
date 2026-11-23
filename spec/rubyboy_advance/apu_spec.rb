# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Apu do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:apu) { described_class.new }
  let(:timer) { RubyboyAdvance::Timer.new(interrupt) }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      [], [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt,
      timer, RubyboyAdvance::Keypad.new(interrupt), apu
    )
  end

  # Steps the timers as exe does: an overflow plays a byte, and a FIFO that has run low gets its DMA
  def step(cycles) = timer.step(cycles) { |id| apu.timer_overflow(id) { |timing| bus.run_dma(timing) } }

  # Left and right as they are now, before the scaling to 16 bits
  def levels
    apu.step(512)
    apu.take_samples.map { it / 64 }
  end

  def play = step(1) && levels

  before do
    bus.write16(0x0400_0084, 0x80) # master enable
    bus.write16(0x0400_0082, 0x0304) # FIFO A: left and right, full volume, timer 0
    bus.write16(0x0400_0100, 0xFFFF)
    bus.write16(0x0400_0102, 0x80) # timer 0 overflows every cycle
  end

  describe 'registers' do
    it 'reads SOUNDCNT_H back without the FIFO reset bits' do
      bus.write16(0x0400_0082, 0xFFFF)

      expect(bus.read16(0x0400_0082)).to eq(0x770F)
    end

    it 'reads back the master enable bit of SOUNDCNT_X' do
      expect(bus.read16(0x0400_0084)).to eq(0x80)

      bus.write16(0x0400_0084, 0x7F)

      expect(bus.read16(0x0400_0084)).to eq(0)
    end
  end

  describe 'SOUNDBIAS' do
    it 'starts at 0x200' do
      expect(bus.read16(0x0400_0088)).to eq(0x200)
    end

    it 'reads back its level, without bit 0, and its sampling bits' do
      bus.write16(0x0400_0088, 0xFFFF)

      expect(bus.read16(0x0400_0088)).to eq(0xC3FE)
    end

    it 'keeps its value when the master enable goes off, and takes writes while it is off' do
      bus.write16(0x0400_0088, 0x4100)
      bus.write16(0x0400_0084, 0)
      expect(bus.read16(0x0400_0088)).to eq(0x4100)

      bus.write16(0x0400_0088, 0x8302)
      bus.write16(0x0400_0084, 0x80)

      expect(bus.read16(0x0400_0088)).to eq(0x8302)
    end

    # FIFO A plays 1, then -127, at full volume: 4, then -508
    {
      0x200 => [4, -508],
      0x100 => [4 - 0x100, -0x200],
      0x3FE => [0x1FF, -508 + 0x1FE],
      0xC200 => [4, -508]
    }.each do |bias, expected|
      it "adds the level of #{format('%#x', bias)}, keeps the sum within 0 to 0x3FF, and takes 0x200 away" do
        bus.write16(0x0400_0088, bias)
        bus.write32(0x0400_00A0, 0x8101)

        expect([play, play]).to eq(expected.map { [it, it] })
      end
    end
  end

  describe 'cycles_to_sample' do
    it 'counts down to the next sample and starts again after it' do
      expect(apu.cycles_to_sample).to eq(512)

      apu.step(500)
      expect(apu.cycles_to_sample).to eq(12)

      apu.step(12 + 100)
      expect(apu.cycles_to_sample).to eq(412)
    end
  end

  describe 'samples' do
    it 'makes one for each side every 512 cycles' do
      apu.step(511)
      expect(apu.take_samples).to eq([])

      apu.step(1)
      expect(apu.take_samples).to eq([0, 0])

      apu.step(1024)
      expect(apu.take_samples).to eq([0, 0, 0, 0])
    end

    it 'scales the 10-bit level to 16 bits' do
      bus.write32(0x0400_00A0, 0x7F)
      step(1)
      apu.step(512)

      expect(apu.take_samples).to eq([127 * 4 * 64] * 2)
    end
  end

  describe 'a FIFO' do
    it 'plays one signed byte, lowest first, at each overflow of its timer' do
      bus.write32(0x0400_00A0, 0x807F_FF01)

      expect(Array.new(4) { play }).to eq([[4, 4], [-4, -4], [508, 508], [-512, -512]])
    end

    it 'holds its level until the next overflow' do
      bus.write32(0x0400_00A0, 1)
      step(1)

      expect([levels, levels]).to eq([[4, 4], [4, 4]])
    end

    it 'falls to 0 when it runs dry' do
      bus.write32(0x0400_00A0, 0x0101_0101)

      expect(Array.new(5) { play }.last).to eq([0, 0])
    end

    {
      'FIFO A at half volume' => [0x0300, 0xA0, [2, 2]],
      'FIFO A on the right only' => [0x0104, 0xA0, [0, 4]],
      'FIFO A on the left only' => [0x0204, 0xA0, [4, 0]],
      'FIFO B at full volume' => [0x3008, 0xA4, [4, 4]],
      'FIFO B at half volume' => [0x3000, 0xA4, [2, 2]],
      'FIFO B on the right only' => [0x1008, 0xA4, [0, 4]],
      'FIFO B on the left only' => [0x2008, 0xA4, [4, 0]]
    }.each do |name, (cnt_h, fifo, expected)|
      it "plays #{name}" do
        bus.write16(0x0400_0082, cnt_h)
        bus.write32(0x0400_0000 + fifo, 1)

        expect(play).to eq(expected)
      end
    end

    it 'adds the two FIFOs' do
      bus.write16(0x0400_0082, 0x3304) # A at full volume, B at half
      bus.write32(0x0400_00A0, 1)
      bus.write32(0x0400_00A4, 0xFD) # -3

      expect(play).to eq([4 - 6, 4 - 6])
    end

    [[0x7F, 0x1FF], [0x80, -0x200]].each do |byte, limit|
      it "keeps the sum of two #{format('%#x', byte)} bytes at #{limit}" do
        bus.write16(0x0400_0082, 0x330C)
        bus.write32(0x0400_00A0, byte)
        bus.write32(0x0400_00A4, byte)

        expect(play).to eq([limit, limit])
      end
    end

    { 'FIFO A with bit 10' => [0x0704, 0xA0], 'FIFO B with bit 14' => [0x7008, 0xA4] }.each do |name, (cnt_h, fifo)|
      it "plays #{name} of SOUNDCNT_H on timer 1" do
        bus.write16(0x0400_0082, cnt_h)
        bus.write32(0x0400_0000 + fifo, 1)
        expect(play).to eq([0, 0]) # only timer 0 runs

        bus.write16(0x0400_0104, 0xFFFF)
        bus.write16(0x0400_0106, 0x80)

        expect(play).to eq([4, 4])
      end
    end

    it 'holds seven words' do
      7.times { |i| bus.write32(0x0400_00A0, i + 1) }

      expect(Array.new(28) { play[0] }).to eq((1..7).flat_map { [it * 4, 0, 0, 0] })
    end

    it 'is emptied by a write when it is full, and takes words again' do
      8.times { |i| bus.write32(0x0400_00A0, i + 1) }
      expect(Array.new(4) { play[0] }).to eq([0, 0, 0, 0])

      bus.write32(0x0400_00A0, 9)

      expect(play[0]).to eq(9 * 4)
    end

    it 'takes a word written a byte at a time' do
      [0x01, 0xFF, 0x7F, 0x80].each_with_index { |byte, i| bus.write(0x0400_00A0 + i, byte) }

      expect(Array.new(4) { play[0] }).to eq([4, -4, 508, -512])
    end

    { 'FIFO A with bit 11' => [0x0800, [8, 8]], 'FIFO B with bit 15' => [0x8000, [4, 4]] }.each do |name, (bit, expected)|
      it "empties #{name} of SOUNDCNT_H" do
        bus.write32(0x0400_00A0, 1)
        bus.write32(0x0400_00A4, 2)

        bus.write16(0x0400_0082, 0x330C | bit)

        expect(play).to eq(expected)
      end
    end
  end

  describe 'through a long DMA' do
    let(:bus) do
      RubyboyAdvance::Bus.new(
        rom, [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt,
        timer, RubyboyAdvance::Keypad.new(interrupt), apu
      )
    end
    let(:cpu) { RubyboyAdvance::Cpu.new(bus) }

    # The samples exe would make, in units of a FIFO byte
    def run_until(count)
      samples = []
      while samples.size < count * 2
        cycles = cpu.exec
        step(cycles)
        apu.step(cycles)
        samples.concat(apu.take_samples)
      end
      samples.each_slice(2).map { |left, _| left / 64 / 4 }
    end

    # DMA3: 1024 words within IWRAM, 2050 cycles, while FIFO A plays a byte every 512 cycles, half-way between samples
    before do
      bus.write32(0x0400_00A0, 0x0403_0201)
      bus.write16(0x0400_0102, 0)
      bus.write16(0x0400_0100, 0x10000 - 256)
      bus.write16(0x0400_0102, 0x80)
      bus.write16(0x0400_0100, 0x10000 - 512)
      bus.write32(0x0400_00D4, 0x0300_0000)
      bus.write32(0x0400_00D8, 0x0300_4000)
      bus.write16(0x0400_00DC, 1024)
      bus.take_cycles
    end

    context 'that an instruction starts' do
      let(:rom) do
        [
          0xE3A00301, # mov r0, #0x04000000
          0xE28000DE, # add r0, r0, #0xDE
          0xE3A01B21, # mov r1, #0x8400
          0xE1C010B0, # strh r1, [r0]: DMA3CNT_H, at once
          0xEAFFFFFE  # b .
        ].pack('V*').bytes
      end

      it 'makes each sample from the byte played by then' do
        expect(run_until(4)).to eq([1, 2, 3, 4])
      end
    end

    context 'that ran between two instructions, as one at HBlank does' do
      let(:rom) { [0xEAFFFFFE].pack('V').bytes } # b .

      it 'makes each sample from the byte played by then' do
        bus.write16(0x0400_00DE, 0x8400)

        expect(run_until(4)).to eq([1, 2, 3, 4])
      end
    end
  end

  describe 'the master enable' do
    it 'ignores FIFO writes while it is off' do
      bus.write16(0x0400_0084, 0)
      bus.write32(0x0400_00A0, 1)
      bus.write16(0x0400_0084, 0x80)

      expect(play).to eq([0, 0])
    end

    it 'empties the FIFOs when it goes off' do
      bus.write32(0x0400_00A0, 1)
      bus.write16(0x0400_0084, 0)
      bus.write16(0x0400_0084, 0x80)

      expect(play).to eq([0, 0])
    end

    it 'is silent and plays nothing while it is off' do
      bus.write32(0x0400_00A0, 0x0201)
      step(1)
      bus.write16(0x0400_0084, 0)
      expect(play).to eq([0, 0])

      bus.write16(0x0400_0084, 0x80)

      expect([levels, play]).to eq([[4, 4], [8, 8]])
    end
  end

  describe 'refills by DMA' do
    before { 40.times { |i| bus.write(0x0200_0000 + i, i + 1) } } # byte i is i + 1

    def start_dma(channel, dad, control)
      base = 0x0400_00B0 + (channel * 12)
      bus.write32(base, 0x0200_0000)
      bus.write32(base + 4, dad)
      bus.write16(base + 10, control)
    end

    it 'plays a stream that DMA1 feeds to FIFO A' do
      start_dma(1, 0x0400_00A0, 0xB640)

      expect(Array.new(40) { play[0] / 4 }).to eq([0, *1..39])
    end

    it 'plays a stream that DMA2 feeds to FIFO B' do
      bus.write16(0x0400_0082, 0x3008)
      start_dma(2, 0x0400_00A4, 0xB640)

      expect(Array.new(40) { play[0] / 4 }).to eq([0, *1..39])
    end

    it 'asks for more only once three words or fewer are left' do
      4.times { bus.write32(0x0400_00A0, 0) }
      start_dma(1, 0x0400_00A0, 0xB440) # without repeat, so the enable bit shows when it has run

      step(1)
      expect(bus.read16(0x0400_00C6)[15]).to eq(1)

      step(1)
      expect(bus.read16(0x0400_00C6)[15]).to eq(0)
    end
  end
end
