# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Cpu do
  let(:bios) { [] }
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      rom,
      bios,
      RubyboyAdvance::Ppu.new(interrupt),
      RubyboyAdvance::Sram.new,
      interrupt,
      RubyboyAdvance::Timer.new(interrupt),
      RubyboyAdvance::Keypad.new(interrupt),
      RubyboyAdvance::Apu.new
    )
  end
  let(:cpu) { described_class.new(bus) }

  def regs = cpu.instance_variable_get(:@regs)
  def cpsr = cpu.instance_variable_get(:@cpsr)
  def spsr_irq = cpu.instance_variable_get(:@spsrs)[:irq]

  # exec hands back cycles left on the bus before it runs anything, so setup that writes through the bus takes them
  def request_vblank
    bus.write16(0x0400_0200, 1) # IE: VBlank
    bus.write16(0x0400_0208, 1) # IME on
    bus.take_cycles
    interrupt.request(:vblank)
  end

  # Stands in for the BIOS: clear IF, then return with subs pc, lr, #4 from IWRAM
  def return_from_irq
    bus.write16(0x0400_0202, 1)
    bus.write32(0x0300_0000, 0xE25EF004)
    bus.take_cycles
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
      bus.take_cycles
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
    let(:rom) { [] }
    let(:code) { [0x00, 0x00, 0xC1, 0xE5] + ([0x00, 0x00, 0xA0, 0xE1] * 5) } # strb r0, [r1], then mov r0, r0

    before do
      regs[0] = 0x01             # bit 7 clear: Halt (bits 0-6 are unused)
      regs[1] = 0x0400_0301      # HALTCNT
      bus.write16(0x0400_0200, 1) # IE: VBlank, with IME left off
      bus.take_cycles
    end

    context 'when written from the BIOS' do
      let(:bios) { code }

      before { regs[15] = 0 }

      it 'takes 1 cycle for each call while stopped' do
        cpu.exec

        expect([cpu.exec, cpu.exec]).to eq([1, 1])
      end

      it 'passes on the cycles of a transfer that ran while it was stopped, and stays stopped' do
        cpu.exec
        bus.read32(0x0200_0000) # stands in for an HBlank DMA

        expect([cpu.exec, cpu.exec, regs[15]]).to eq([6, 1, 0x04])
      end

      it 'stops the CPU until an enabled interrupt is requested, even with IME off' do
        4.times { cpu.exec }

        expect(regs[15]).to eq(0x04)

        interrupt.request(:vblank)
        cpu.exec

        expect(regs[15]).to eq(0x08)
      end

      it 'does not stop again once IF is cleared' do
        cpu.exec
        interrupt.request(:vblank)
        cpu.exec
        bus.write16(0x0400_0202, 1) # clear IF
        bus.take_cycles
        cpu.exec

        expect(regs[15]).to eq(0x0C)
      end
    end

    context 'when written from outside the BIOS' do
      let(:rom) { code }

      it 'is ignored' do
        2.times { cpu.exec }

        expect(regs[15]).to eq(0x0800_0008)
      end
    end
  end

  describe 'cycles' do
    let(:nop) { [0x00, 0x00, 0xA0, 0xE1] } # mov r0, r0
    let(:rom) { nop * 4 }

    it 'takes three opcode reads after a jump, the first at the full cost, and one for each instruction after it' do
      expect([cpu.exec, cpu.exec]).to eq([8 + 6 + 6, 6])
    end

    it 'reads Thumb opcodes as halfwords' do
      cpu.instance_variable_set(:@cpsr, 0x3F)

      expect([cpu.exec, cpu.exec]).to eq([5 + 3 + 3, 3])
    end

    context 'with a load in the ROM' do
      let(:rom) { [0x00, 0x00, 0x91, 0xE5] + (nop * 5) } # ldr r0, [r1]

      it 'reads the opcode after a data access at the full cost' do
        regs[1] = 0x0300_0000

        expect([cpu.exec, cpu.exec, cpu.exec]).to eq([8 + 6 + 6 + 1 + 1, 8, 6])
      end
    end

    context 'with ldm in the ROM' do
      let(:rom) { [0x0C, 0x00, 0x91, 0xE8] + (nop * 5) } # ldmia r1, {r2, r3}

      it 'reads the words after the first as sequential' do
        regs[1] = 0x0800_0010

        expect(cpu.exec).to eq(8 + 6 + 6 + 8 + 6 + 1)
      end
    end

    it 'hands back the cycles a DMA left on the bus before it runs anything' do
      bus.read32(0x0200_0000) # stands in for an HBlank DMA

      expect([cpu.exec, regs[15], cpu.exec, regs[15]]).to eq([6, 0x0800_0000, 8 + 6 + 6, 0x0800_0004])
    end

    context 'when it takes an IRQ' do
      let(:bios) { nop * 16 }

      before do
        bus.write16(0x0400_0200, 1) # IE: VBlank
        bus.write16(0x0400_0208, 1) # IME on
        bus.take_cycles
      end

      it 'reads one more opcode where it was, then three at the vector' do
        cpu.exec
        interrupt.request(:vblank)

        expect([cpu.exec, cpu.exec, regs[15]]).to eq([6, 3, 0x1C])
      end

      it 'reads the three opcodes that a jump before it still owed' do
        interrupt.request(:vblank)

        expect([cpu.exec, cpu.exec]).to eq([8 + 6 + 6, 3])
      end

      context 'from Thumb' do
        let(:rom) { [0xC0, 0x46] * 8 } # mov r8, r8

        it 'reads a halfword where it was' do
          cpu.instance_variable_set(:@cpsr, 0x3F)
          cpu.exec
          interrupt.request(:vblank)

          expect([cpu.exec, cpu.exec]).to eq([3, 3])
        end
      end
    end

    context 'with a shift by a register in the ROM' do
      let(:rom) { [0x11, 0x02, 0xA0, 0xE1] + (nop * 5) } # mov r0, r1, lsl r2

      it 'reads the opcode after an internal cycle at the full cost' do
        expect([cpu.exec, cpu.exec, cpu.exec]).to eq([8 + 6 + 6 + 1, 8, 6])
      end
    end

    describe 'internal cycles' do
      let(:rom) { [] }
      let(:base) { 0x0300_0000 }

      before do
        regs[1] = 0x0300_0100
        regs[2] = 0
      end

      # Cycles of one instruction in IWRAM past its opcode reads: 1 for each data access, plus the internal ones
      def cycles_past_fetch(opcode, thumb: false)
        thumb ? bus.write16(base, opcode) : bus.write32(base, opcode)
        cpu.instance_variable_set(:@cpsr, 0x3F) if thumb
        regs[15] = base
        bus.take_cycles
        cpu.exec - 3
      end

      {
        'mov r0, r1, lsl #2' => [0xE1A00101, 0],
        'mov r0, r1, lsl r2' => [0xE1A00211, 1],
        'moveq r0, r1, lsl r2, not run' => [0x01A00211, 0],
        'str r0, [r1]' => [0xE5810000, 1],
        'ldr r0, [r1]' => [0xE5910000, 1 + 1],
        'ldrb r0, [r1]' => [0xE5D10000, 1 + 1],
        'ldrh r0, [r1]' => [0xE1D100B0, 1 + 1],
        'ldrsb r0, [r1]' => [0xE1D100D0, 1 + 1],
        'ldrsh r0, [r1]' => [0xE1D100F0, 1 + 1],
        'stmia r1, {r2, r3}' => [0xE881000C, 2],
        'ldmia r1, {r2, r3}' => [0xE891000C, 2 + 1],
        'ldmia r1, {}' => [0xE8910000, 1 + 1],
        'swp r0, r2, [r1]' => [0xE1010092, 2 + 1],
        'swpb r0, r2, [r1]' => [0xE1410092, 2 + 1]
      }.each do |name, (opcode, cycles)|
        it "takes #{cycles} for #{name}" do
          expect(cycles_past_fetch(opcode)).to eq(cycles)
        end
      end

      it 'takes one internal cycle for ldrsh from an odd address, which loads a byte' do
        regs[1] = 0x0300_0101

        expect(cycles_past_fetch(0xE1D100F0)).to eq(1 + 1)
      end

      {
        0x0000_00FF => 1, 0x0000_0100 => 2, 0x0000_FFFF => 2, 0x0001_0000 => 3, 0x00FF_FFFF => 3, 0x0100_0000 => 4,
        0xFFFF_FF00 => 1, 0xFFFF_FEFF => 2, 0xFFFF_0000 => 2, 0xFFFE_FFFF => 3, 0xFF00_0000 => 3, 0xFEFF_FFFF => 4
      }.each do |multiplier, cycles|
        it "takes #{cycles} for mul by #{format('%#010x', multiplier)}, and one more for each extra step of the others" do
          regs[2] = multiplier
          mul, mla, smull, smlal = [0xE0000291, 0xE0203291, 0xE0C54291, 0xE0E54291].map { cycles_past_fetch(it) }

          expect([mul, mla, smull, smlal]).to eq([cycles, cycles + 1, cycles + 1, cycles + 2])
        end
      end

      { 0x0000_00FF => 1, 0x0000_0100 => 2, 0x00FF_FFFF => 3, 0x0100_0000 => 4, 0xFFFF_FF00 => 4 }.each do |multiplier, cycles|
        it "takes #{cycles + 1} for umull by #{format('%#010x', multiplier)}, where upper ones do not count, and one more for umlal" do
          regs[2] = multiplier

          expect([cycles_past_fetch(0xE0854291), cycles_past_fetch(0xE0A54291)]).to eq([cycles + 1, cycles + 2])
        end
      end

      describe 'in Thumb' do
        {
          'lsl r0, r1, #2' => [0x0088, 0],
          'and r0, r1' => [0x4008, 0],
          'lsl r0, r1' => [0x4088, 1],
          'lsr r0, r1' => [0x40C8, 1],
          'asr r0, r1' => [0x4108, 1],
          'ror r0, r1' => [0x41C8, 1],
          'str r0, [r1]' => [0x6008, 1],
          'ldr r0, [pc]' => [0x4800, 1 + 1],
          'ldr r0, [r1, r2]' => [0x5888, 1 + 1],
          'ldrb r0, [r1, r2]' => [0x5C88, 1 + 1],
          'ldrsb r0, [r1, r2]' => [0x5688, 1 + 1],
          'ldrh r0, [r1, r2]' => [0x5A88, 1 + 1],
          'ldrsh r0, [r1, r2]' => [0x5E88, 1 + 1],
          'ldr r0, [r1]' => [0x6808, 1 + 1],
          'ldrb r0, [r1]' => [0x7808, 1 + 1],
          'ldrh r0, [r1]' => [0x8808, 1 + 1],
          'ldr r0, [sp]' => [0x9800, 1 + 1],
          'push {r0, r1}' => [0xB403, 2],
          'pop {r0, r1}' => [0xBC03, 2 + 1],
          'pop {pc}' => [0xBD00, 1 + 1],
          'stmia r1!, {r2, r3}' => [0xC10C, 2],
          'ldmia r1!, {r2, r3}' => [0xC90C, 2 + 1]
        }.each do |name, (opcode, cycles)|
          it "takes #{cycles} for #{name}" do
            expect(cycles_past_fetch(opcode, thumb: true)).to eq(cycles)
          end
        end

        it 'takes the cycles of mul from the value of rd' do
          regs[0] = 0x0012_3456
          regs[1] = 0x12

          expect(cycles_past_fetch(0x4348, thumb: true)).to eq(3) # mul r0, r1
        end
      end
    end

    it 'adds the data accesses of the instruction' do
      [0xE5910000, 0xE5810000].each_with_index { |opcode, i| bus.write32(0x0300_0000 + (i * 4), opcode) } # ldr r0, [r1]; str r0, [r1]
      regs[1] = 0x0200_0000
      regs[15] = 0x0300_0000
      bus.take_cycles

      expect([cpu.exec, cpu.exec]).to eq([3 + 6 + 1, 1 + 6])
    end
  end

  describe 'prefetch' do
    let(:rom) { [] }
    let(:base) { 0x0300_0000 }

    def run_arm(*opcodes)
      opcodes.each_with_index { |opcode, i| bus.write32(base + (i * 4), opcode) }
      bus.take_cycles
      regs[15] = base
      opcodes.size.times { cpu.exec }
    end

    it 'runs the two ARM instructions it has read even when the ones before rewrite them' do
      regs[1] = base + 8
      regs[2] = base + 12

      run_arm(0xE5810000, 0xE5820000, 0xE3A03001, 0xE3A04002) # str r0, [r1]; str r0, [r2]; mov r3, #1; mov r4, #2

      expect([regs[3], regs[4]]).to eq([1, 2])
    end

    it 'reads an ARM instruction three ahead after it is rewritten' do
      regs[1] = base + 12
      regs[5] = 0xE3A04009 # mov r4, #9

      run_arm(0xE5815000, 0xE1A00000, 0xE1A00000, 0xE3A04002) # str r5, [r1]; mov r0, r0; mov r0, r0; mov r4, #2

      expect(regs[4]).to eq(9)
    end

    it 'reads again after a branch, even to the next instruction' do
      regs[1] = base + 8
      regs[5] = 0xE3A04009 # mov r4, #9

      run_arm(0xE5815000, 0xEAFFFFFF, 0xE3A04002) # str r5, [r1]; b to the next; mov r4, #2

      expect(regs[4]).to eq(9)
    end

    { 'mov pc, r2' => 0xE1A0F002, 'ldr pc, [r3]' => 0xE593F000, 'ldmia r3, {pc}' => 0xE8938000 }.each do |name, jump|
      it "reads again after #{name}, even to the next instruction" do
        bus.write32(0x0300_0100, base + 8)
        regs[1] = base + 8
        regs[2] = base + 8
        regs[3] = 0x0300_0100
        regs[5] = 0xE3A04009 # mov r4, #9

        run_arm(0xE5815000, jump, 0xE3A04002) # str r5, [r1]; the jump; mov r4, #2

        expect(regs[4]).to eq(9)
      end
    end

    it 'reads Thumb instructions again after movs pc returns to Thumb at the next address' do
      bus.write16(base + 4, 0x2409) # mov r4, #9
      bus.write16(base + 6, 0x2502) # mov r5, #2
      cpu.instance_variable_set(:@cpsr, 0x13) # SVC
      cpu.instance_variable_get(:@spsrs)[:svc] = 0x3F # System, Thumb
      regs[0] = base + 4

      run_arm(0xE1B0F000) # movs pc, r0
      2.times { cpu.exec }

      expect([regs[4], regs[5]]).to eq([9, 2])
    end

    describe 'in Thumb' do
      def run_thumb(*opcodes)
        opcodes.each_with_index { |opcode, i| bus.write16(base + (i * 2), opcode) }
        bus.take_cycles
        regs[15] = base
        cpu.instance_variable_set(:@cpsr, 0x3F)
        opcodes.size.times { cpu.exec }
      end

      it 'runs the two instructions it has read even when the ones before rewrite them' do
        regs[1] = base + 4
        regs[2] = base + 6

        run_thumb(0x8008, 0x8010, 0x2301, 0x2402) # strh r0, [r1]; strh r0, [r2]; mov r3, #1; mov r4, #2

        expect([regs[3], regs[4]]).to eq([1, 2])
      end

      { 'mov pc, r2' => 0x4697, 'pop {pc}' => 0xBD00 }.each do |name, jump|
        it "reads again after #{name}, even to the next instruction" do
          regs[1] = base + 4
          regs[2] = base + 4
          regs[5] = 0x2409 # mov r4, #9
          regs[13] = 0x0300_0100
          bus.write32(0x0300_0100, base + 4)

          run_thumb(0x800D, jump, 0x2402) # strh r5, [r1]; the jump; mov r4, #2

          expect(regs[4]).to eq(9)
        end
      end
    end
  end
end
