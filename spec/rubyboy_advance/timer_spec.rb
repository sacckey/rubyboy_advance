# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Timer do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:timer) { described_class.new(interrupt) }
  let(:overflowed) { [] }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      [],
      [],
      RubyboyAdvance::Ppu.new(interrupt),
      RubyboyAdvance::Sram.new,
      interrupt,
      timer,
      RubyboyAdvance::Keypad.new(interrupt),
      RubyboyAdvance::Apu.new
    )
  end

  def start(index, reload, control)
    bus.write16(0x0400_0100 + (index * 4), reload)
    bus.write16(0x0400_0102 + (index * 4), control)
  end

  def counter(index) = bus.read16(0x0400_0100 + (index * 4))
  def requested = bus.read16(0x0400_0202)
  # The block hears of each overflow of timers 0 and 1, which exe passes on to the APU
  def step(cycles) = timer.step(cycles) { overflowed << it }
  def run(cycles) = cycles.times { step(1) }

  describe 'registers' do
    it 'starts from the reload value and reads back the counter' do
      start(2, 0xFF00, 0x80)
      run(5)
      bus.write16(0x0400_0108, 0x1234) # only sets the next reload value

      expect([counter(2), bus.read16(0x0400_010A)]).to eq([0xFF05, 0x80])
    end

    it 'does not restart when written while running' do
      start(0, 0x1000, 0x80)
      run(5)
      bus.write16(0x0400_0102, 0x80)

      expect(counter(0)).to eq(0x1005)
    end

    it 'keeps the prescaler on the running clock when re-enabled' do
      start(0, 0, 0x81)
      run(63)
      bus.write16(0x0400_0102, 0x01)
      bus.write16(0x0400_0102, 0x81)
      run(1)

      expect(counter(0)).to eq(1)
    end

    it 'does not jump when the prescaler changes while running' do
      start(0, 0, 0x83)
      run(63)
      bus.write16(0x0400_0102, 0x80)
      run(1)

      expect(counter(0)).to eq(1)
    end
  end

  describe 'counting' do
    it 'does not count while disabled' do
      bus.write16(0x0400_0100, 0x1234)
      run(10)

      expect(counter(0)).to eq(0)
    end

    { 0 => 1, 1 => 64, 2 => 256, 3 => 1024 }.each do |bits, cycles|
      it "counts once every #{cycles} cycles with prescaler #{bits}" do
        start(0, 0, 0x80 | bits)
        run(cycles - 1)

        expect(counter(0)).to eq(0)

        run(1)

        expect(counter(0)).to eq(1)
      end
    end

    it 'reloads on overflow and requests its interrupt when bit 6 is set' do
      start(2, 0xFFFE, 0xC0)
      run(1)

      expect([counter(2), requested]).to eq([0xFFFF, 0])

      run(1)

      expect([counter(2), requested]).to eq([0xFFFE, 1 << 5])
    end

    it 'does not request an interrupt without bit 6' do
      start(2, 0xFFFF, 0x80)
      run(1)

      expect(requested).to eq(0)
    end

    it 'keeps the cycles past an overflow' do
      start(0, 0xFFFE, 0x80)
      step(3)

      expect(counter(0)).to eq(0xFFFF)
    end

    it 'handles every overflow in one step' do
      start(0, 0xFFFE, 0x80)
      start(1, 0, 0x84)
      step(4)

      expect([counter(0), counter(1)]).to eq([0xFFFE, 2])
    end
  end

  describe 'cycles_to_overflow' do
    it 'is far off with no timer running' do
      expect(timer.cycles_to_overflow).to be > 1_000_000_000
    end

    { 0 => 1, 1 => 64, 2 => 256, 3 => 1024 }.each do |bits, cycles|
      it "counts #{cycles} cycles for each count left with prescaler #{bits}, from where the prescaler stands" do
        step(10) # the prescalers run on this clock whether a timer is on or not
        start(0, 0xFFFD, 0x80 | bits)

        expect(timer.cycles_to_overflow).to eq((3 * cycles) - (10 % cycles))
      end
    end

    it 'is right at every cycle up to the overflow' do
      start(1, 0xFFFE, 0x81)
      seen = Array.new(128) do
        left = timer.cycles_to_overflow
        step(1)
        left
      end

      expect(seen).to eq(128.downto(1).to_a)
      expect(overflowed).to eq([1])
    end

    it 'is the nearest of the timers that are running' do
      start(0, 0xFFF0, 0x80)
      start(2, 0xFFFF, 0x81)
      start(3, 0xFF00, 0x80)

      expect(timer.cycles_to_overflow).to eq(16)
    end

    it 'counts to the next overflow once one has happened' do
      start(0, 0xFFFE, 0x80)
      step(2)

      expect([overflowed, timer.cycles_to_overflow]).to eq([[0], 2])
    end

    it 'leaves out a timer that counts overflows, and a timer that is off' do
      start(0, 0xFF00, 0x80)
      start(1, 0xFFFF, 0x84) # counts up
      bus.write16(0x0400_0108, 0xFFFF) # TM2 reload, not started

      expect(timer.cycles_to_overflow).to eq(0x100)
    end

    it 'takes TM0 as counting the clock even with the count-up bit' do
      start(0, 0xFFFC, 0x84)

      expect(timer.cycles_to_overflow).to eq(4)
    end
  end

  describe 'overflows for the sound FIFOs' do
    it 'yields the timer once for each overflow' do
      start(0, 0xFFFE, 0x80)
      step(5)

      expect(overflowed).to eq([0, 0])
    end

    it 'yields timer 1 when counting up makes it overflow' do
      start(0, 0xFFFF, 0x80)
      start(1, 0xFFFF, 0x84)
      step(1)

      expect(overflowed).to eq([0, 1])
    end

    # exe starts a sound DMA from the block, and that can read and write the timers
    it 'has every timer up to date by the time it yields' do
      start(0, 0xFFC0, 0x80)
      start(1, 0xFFD0, 0x80) # overflows in the same step, 16 cycles before its end
      start(3, 0xFF00, 0x80)
      seen = []
      timer.step(64) { |id| seen << [id, counter(0), counter(1), counter(3)] }

      expect(seen).to eq([[0, 0xFFC0, 0xFFE0, 0xFF40], [1, 0xFFC0, 0xFFE0, 0xFF40]])
    end

    it 'counts the step once when a timer is written while it yields' do
      start(0, 0xFFC0, 0x80)
      start(2, 0xFF00, 0x80)
      timer.step(64) do |id|
        overflowed << id
        bus.write16(0x0400_010E, 0) # TM3 control
      end

      expect([overflowed, counter(0), counter(2)]).to eq([[0], 0xFFC0, 0xFF40])
    end

    it 'does not yield timers 2 and 3' do
      start(2, 0xFFFF, 0x80)
      start(3, 0xFFFF, 0x80)
      step(2)

      expect(overflowed).to eq([])
    end
  end

  describe 'count-up' do
    it 'counts overflows of the timer before it' do
      start(0, 0xFE00, 0x80)
      start(1, 0xFF60, 0xC4)
      run((512 * 160) - 1)

      expect(requested).to eq(0)

      run(1)

      expect([counter(1), requested]).to eq([0xFF60, 1 << 4])
    end

    it 'ignores the prescaler' do
      start(0, 0xFFFF, 0x80)
      start(1, 0, 0x87)
      run(2)

      expect(counter(1)).to eq(2)
    end

    it 'does not count while it is off itself' do
      start(0, 0xFFFF, 0x80)
      start(1, 0xFF00, 0x84)
      step(2)
      bus.write16(0x0400_0106, 0x04) # TM1 off, still set to count up
      step(3)

      expect(counter(1)).to eq(0xFF02)
    end

    it 'does not count when the timer before it is off' do
      start(0, 0xFFFF, 0x80)
      start(2, 0, 0x84) # TM1 is off
      run(3)

      expect(counter(2)).to eq(0)
    end

    it 'does not count when the timer before it does not overflow' do
      start(0, 0xFFFF, 0x80)
      start(1, 0, 0x84)
      start(2, 0, 0x84)
      run(3)

      expect(counter(2)).to eq(0)
    end

    it 'is ignored on TM0' do
      start(0, 0, 0x84)
      run(5)

      expect(counter(0)).to eq(5)
    end

    it 'leaves the cycles for the timers after it' do
      start(0, 0, 0x80)
      start(1, 0, 0x84)
      start(2, 0, 0x80)
      step(3)

      expect(counter(2)).to eq(3)
    end
  end
end
