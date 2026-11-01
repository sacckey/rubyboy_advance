# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Keypad do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:keypad) { described_class.new(interrupt) }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      [],
      [],
      RubyboyAdvance::Ppu.new(interrupt),
      RubyboyAdvance::Sram.new,
      interrupt,
      RubyboyAdvance::Timer.new(interrupt),
      keypad
    )
  end

  it 'reads 0x03FF while no key is held' do
    expect(bus.read16(0x0400_0130)).to eq(0x03FF)
  end

  it 'reads 0 for the held keys' do
    keypad.update(0b10_0000_0001) # A and L

    expect(bus.read16(0x0400_0130)).to eq(0x01FE)
  end

  it 'reads 0x03FF again once the keys are released' do
    keypad.update(0b10_0000_0001)
    keypad.update(0)

    expect(bus.read16(0x0400_0130)).to eq(0x03FF)
  end

  it 'ignores writes' do
    bus.write16(0x0400_0130, 0)

    expect(bus.read16(0x0400_0130)).to eq(0x03FF)
  end
end
