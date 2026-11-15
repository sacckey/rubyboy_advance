# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Interrupt do
  let(:interrupt) { described_class.new }

  it 'asks for an IRQ once a request is enabled and IME is on, in whatever order they come' do
    interrupt.request(:vblank)
    expect(interrupt.irq?).to be(false)

    interrupt.write(0x200, 1) # IE: VBlank
    expect(interrupt.irq?).to be(false)

    interrupt.write(0x208, 1) # IME on
    expect(interrupt.irq?).to be(true)
  end

  it 'stops asking once the request is acknowledged' do
    interrupt.write(0x200, 1)
    interrupt.write(0x208, 1)
    interrupt.request(:vblank)

    interrupt.write(0x202, 1) # IF: VBlank

    expect(interrupt.irq?).to be(false)
  end

  it 'wakes a halted CPU when a waiting request gets enabled, even with IME off' do
    interrupt.request(:vblank)
    interrupt.write(0x301, 0) # HALTCNT
    expect(interrupt.cpu_halted?).to be(true)

    interrupt.write(0x200, 1)

    expect([interrupt.cpu_halted?, interrupt.irq?]).to eq([false, false])
  end
end
