# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Timer do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:timer) { described_class.new(interrupt) }
  let(:bus) { RubyboyAdvance::Bus.new([], [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt, timer) }

  def start(index, reload, control)
    bus.write16(0x0400_0100 + (index * 4), reload)
    bus.write16(0x0400_0102 + (index * 4), control)
  end

  def counter(index) = bus.read16(0x0400_0100 + (index * 4))
  def requested = bus.read16(0x0400_0202)
  def run(cycles) = cycles.times { timer.step(1) }

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
      timer.step(3)

      expect(counter(0)).to eq(0xFFFF)
    end

    it 'handles every overflow in one step' do
      start(0, 0xFFFE, 0x80)
      start(1, 0, 0x84)
      timer.step(4)

      expect([counter(0), counter(1)]).to eq([0xFFFE, 2])
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
      timer.step(3)

      expect(counter(2)).to eq(3)
    end
  end
end
