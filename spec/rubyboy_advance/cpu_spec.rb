# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Cpu do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:bus) { RubyboyAdvance::Bus.new(rom, RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt) }
  let(:cpu) { described_class.new(bus) }

  def regs = cpu.instance_variable_get(:@regs)
  def cpsr = cpu.instance_variable_get(:@cpsr)
  def spsr_irq = cpu.instance_variable_get(:@spsrs)[:irq]

  def request_vblank
    bus.write16(0x0400_0200, 1) # IE: VBlank
    bus.write16(0x0400_0208, 1) # IME on
    interrupt.request(:vblank)
  end

  # The game's handler, registered at 0x03007FFC for the BIOS to call. It acknowledges
  # VBlank in IF and overwrites r1 and r2, which the BIOS has to restore.
  def install_handler
    [
      0xE3A01301, # mov r1, #0x04000000
      0xE2811C02, # add r1, r1, #0x200
      0xE3A02001, # mov r2, #1
      0xE1C120B2, # strh r2, [r1, #2]
      0xE12FFF1E  # bx lr
    ].each_with_index { |opcode, i| bus.write32(0x0300_0100 + (i * 4), opcode) }
    bus.write32(0x0300_7FFC, 0x0300_0100)
  end

  def run_until_back_in_rom
    20.times do
      cpu.exec
      return if regs[15] >> 24 == 0x08
    end

    raise 'never returned from the IRQ'
  end

  describe 'IRQ' do
    before { install_handler }

    context 'from ARM' do
      let(:rom) { [0x00, 0x00, 0xA0, 0xE1] * 2 } # mov r0, r0

      it 'enters IRQ mode at 0x18' do
        cpu.exec
        request_vblank
        cpu.exec

        expect([regs[15], regs[14], cpsr, spsr_irq]).to eq([0x18, 0x0800_0008, 0x92, 0x1F])
      end

      it 'calls the handler through the BIOS and returns to the next instruction' do
        cpu.exec
        regs[0, 4] = [0x11, 0x22, 0x33, 0x44]
        request_vblank
        run_until_back_in_rom

        expect([regs[15], regs[13], cpsr]).to eq([0x0800_0004, 0x0300_7F00, 0x1F])
        expect(regs[0, 4]).to eq([0x11, 0x22, 0x33, 0x44])
        expect(bus.read16(0x0400_0202)).to eq(0)
      end

      it 'waits while CPSR.I is set' do
        cpu.instance_variable_set(:@cpsr, 0x9F)
        request_vblank
        cpu.exec

        expect(regs[15]).to eq(0x0800_0004)
      end
    end

    context 'from Thumb' do
      let(:rom) { [0xC0, 0x46] * 2 } # mov r8, r8

      it 'runs the handler in ARM and comes back to Thumb' do
        cpu.instance_variable_set(:@cpsr, 0x3F)
        cpu.exec
        request_vblank
        cpu.exec

        expect([regs[15], regs[14], cpsr]).to eq([0x18, 0x0800_0006, 0x92])

        run_until_back_in_rom

        expect([regs[15], cpsr]).to eq([0x0800_0002, 0x3F])
      end
    end
  end
end
