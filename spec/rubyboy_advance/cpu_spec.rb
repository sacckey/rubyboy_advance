# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Cpu do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:bus) { RubyboyAdvance::Bus.new(rom, [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt) }
  let(:cpu) { described_class.new(bus) }

  def regs = cpu.instance_variable_get(:@regs)
  def cpsr = cpu.instance_variable_get(:@cpsr)
  def spsr_irq = cpu.instance_variable_get(:@spsrs)[:irq]

  def request_vblank
    bus.write16(0x0400_0200, 1) # IE: VBlank
    bus.write16(0x0400_0208, 1) # IME on
    interrupt.request(:vblank)
  end

  # Stands in for the BIOS: clear IF, then return with subs pc, lr, #4 from IWRAM
  def return_from_irq
    bus.write16(0x0400_0202, 1)
    bus.write32(0x0300_0000, 0xE25EF004)
    regs[15] = 0x0300_0000
    cpu.exec
  end

  describe 'IRQ' do
    context 'from ARM' do
      let(:rom) { [0x00, 0x00, 0xA0, 0xE1] * 2 } # mov r0, r0

      it 'enters IRQ mode at 0x18 and returns to the next instruction' do
        cpu.exec
        request_vblank
        cpu.exec

        expect([regs[15], regs[14], cpsr, spsr_irq]).to eq([0x18, 0x0800_0008, 0x92, 0x1F])

        return_from_irq

        expect([regs[15], regs[13], cpsr]).to eq([0x0800_0004, 0x0300_7F00, 0x1F])
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

      it 'switches to ARM for the handler and comes back to Thumb' do
        cpu.instance_variable_set(:@cpsr, 0x3F)
        cpu.exec
        request_vblank
        cpu.exec

        expect([regs[15], regs[14], cpsr]).to eq([0x18, 0x0800_0006, 0x92])

        return_from_irq

        expect([regs[15], cpsr]).to eq([0x0800_0002, 0x3F])
      end
    end
  end

  describe 'SWI' do
    def spsr_svc = cpu.instance_variable_get(:@spsrs)[:svc]

    # Stands in for the BIOS: return with movs pc, lr from IWRAM
    def return_from_swi
      bus.write32(0x0300_0000, 0xE1B0F00E)
      regs[15] = 0x0300_0000
      cpu.exec
    end

    context 'from ARM' do
      let(:rom) { [0x06, 0x00, 0x00, 0xEF] } # swi 6

      it 'enters Supervisor mode at 0x08 and returns to the next instruction' do
        cpu.exec

        expect([regs[15], regs[14], regs[13], cpsr, spsr_svc]).to eq([0x08, 0x0800_0004, 0x0300_7FE0, 0x93, 0x1F])

        return_from_swi

        expect([regs[15], regs[13], cpsr]).to eq([0x0800_0004, 0x0300_7F00, 0x1F])
      end
    end

    context 'from Thumb' do
      let(:rom) { [0x06, 0xDF] } # swi 6

      it 'switches to ARM in Supervisor mode and comes back to Thumb' do
        cpu.instance_variable_set(:@cpsr, 0x3F)
        cpu.exec

        expect([regs[15], regs[14], cpsr, spsr_svc]).to eq([0x08, 0x0800_0002, 0x93, 0x3F])

        return_from_swi

        expect([regs[15], cpsr]).to eq([0x0800_0002, 0x3F])
      end
    end
  end

  describe 'HALTCNT' do
    let(:rom) { [0x00, 0x00, 0xA0, 0xE1] * 4 } # mov r0, r0

    def halt_until_vblank
      cpu.exec
      bus.write(0x0400_0301, 0x01) # bit 7 clear: Halt (bits 0-6 are unused)
      bus.write16(0x0400_0200, 1)  # IE: VBlank, with IME left off
    end

    it 'stops the CPU until an enabled interrupt is requested, even with IME off' do
      halt_until_vblank
      3.times { cpu.exec }

      expect(regs[15]).to eq(0x0800_0004)

      interrupt.request(:vblank)
      cpu.exec

      expect(regs[15]).to eq(0x0800_0008)
    end

    it 'does not stop again once IF is cleared' do
      halt_until_vblank
      interrupt.request(:vblank)
      cpu.exec
      bus.write16(0x0400_0202, 1) # clear IF
      cpu.exec

      expect(regs[15]).to eq(0x0800_000C)
    end
  end
end
