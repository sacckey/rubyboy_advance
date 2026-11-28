# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Cpu do
  let(:bios) { [] }
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  # exec runs on until an event is due. One cycle before a sample, that is after every instruction
  let(:apu) { RubyboyAdvance::Apu.new.tap { it.step(511) } }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      rom,
      bios,
      RubyboyAdvance::Ppu.new(interrupt),
      RubyboyAdvance::Sram.new,
      interrupt,
      RubyboyAdvance::Timer.new(interrupt),
      RubyboyAdvance::Keypad.new(interrupt),
      apu
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

      it 'sleeps until the next event for each call while stopped' do
        cpu.exec

        expect([cpu.exec, cpu.exec]).to eq([1, 1]) # the next sample of the APU, which nothing steps here
      end

      it 'sleeps no longer than until a timer overflows' do
        cpu.exec
        apu.step(1) # the next sample is now 512 cycles away
        bus.write16(0x0400_0100, 0xFFFD)
        bus.write16(0x0400_0102, 0x80)
        bus.take_cycles

        expect(cpu.exec).to eq(3)
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

  describe 'running on to an event' do
    let(:nop) { [0x00, 0x00, 0xA0, 0xE1] } # mov r0, r0, 8 + 6 + 6 cycles for the first and 6 for the others
    let(:rom) { nop * 8 }
    let(:apu) { RubyboyAdvance::Apu.new } # its next sample, the first event, is 512 cycles away

    it 'runs instructions until an event is due and hands back the time of them all' do
      apu.step(512 - 26)

      expect([cpu.exec, regs[15]]).to eq([20 + 6, 0x0800_0008])
    end

    context 'with a write to an I/O register' do
      let(:rom) { (nop * 2) + [0x00, 0x00, 0xC1, 0xE5] + (nop * 5) } # strb r0, [r1]

      it 'stops after one past the LCD registers, which may move the next event' do
        regs[1] = 0x0400_0208 # IME
        cpu.exec

        expect(regs[15]).to eq(0x0800_000C)
      end

      it 'runs on after one to an LCD register' do
        regs[1] = 0x0400_0000 # DISPCNT
        cpu.exec

        expect(regs[15]).to be > 0x0800_000C
      end

      it 'starts a timer from the time of the instruction that switches it on' do
        bus.write16(0x0400_0100, 0xFFF0)
        bus.take_cycles
        regs[0] = 0x80
        regs[1] = 0x0400_0102 # TM0CNT_H
        cpu.exec

        expect(bus.cycles_to_event).to eq(20 + 6 + 0x10)
      end
    end

    context 'with a read of a timer' do
      let(:rom) { (nop * 2) + [0xB0, 0x00, 0xD1, 0xE1] + (nop * 5) } # ldrh r0, [r1]

      it 'reads the counter as it is when the instruction starts' do
        bus.write16(0x0400_0102, 0x80)
        bus.take_cycles
        regs[1] = 0x0400_0100 # TM0CNT_L
        cpu.exec

        expect(regs[0]).to eq(20 + 6)
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

    it 'hands back the time of a long DMA 64 cycles at a time, and then goes on' do
      bus.idle(150)

      expect([Array.new(4) { cpu.exec }, regs[15]]).to eq([[64, 64, 22, 8 + 6 + 6], 0x0800_0004])
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

  # Written so that no value passes 64 bits, which the expectations here work out with numbers of any size
  describe 'arithmetic' do
    let(:rom) { [] }
    let(:base) { 0x0300_0000 }

    def run(opcode, thumb: false)
      thumb ? bus.write16(base, opcode) : bus.write32(base, opcode)
      cpu.instance_variable_set(:@cpsr, cpsr | 0x20) if thumb
      regs[15] = base
      bus.take_cycles
      cpu.exec
    end

    def s32(n) = n[31] == 1 ? n - 0x1_0000_0000 : n
    def words(n) = [(n >> 32) & 0xFFFF_FFFF, n & 0xFFFF_FFFF]

    {
      'movs of 0' => [0xE3B00000, [0, 1]], 'movs of 1' => [0xE3B00001, [0, 0]],
      'movs of 0x80000000' => [0xE3B00102, [1, 0]], 'mvns of 0' => [0xE3F00000, [1, 0]]
    }.each do |name, (opcode, flags)|
      it "sets N and Z to #{flags.join(' and ')} for #{name}, whatever they were" do
        got = [0x1F, 0xC000_001F].map do |before|
          cpu.instance_variable_set(:@cpsr, before)
          run(opcode)
          [cpsr[31], cpsr[30]]
        end

        expect(got).to eq([flags, flags])
      end
    end

    # Bit NZCV of each mask says whether the condition holds with those flags
    {
      'EQ' => 0xF0F0, 'NE' => 0x0F0F, 'CS' => 0xCCCC, 'CC' => 0x3333, 'MI' => 0xFF00, 'PL' => 0x00FF, 'VS' => 0xAAAA, 'VC' => 0x5555,
      'HI' => 0x0C0C, 'LS' => 0xF3F3, 'GE' => 0xAA55, 'LT' => 0x55AA, 'GT' => 0x0A05, 'LE' => 0xF5FA, 'AL' => 0xFFFF, 'NV' => 0x0000
    }.each_with_index do |(name, mask), condition|
      it "runs an instruction with the condition #{name} for the flags that it names" do
        ran = (0..15).select do |flags|
          regs[0] = 0
          cpu.instance_variable_set(:@cpsr, (flags << 28) | 0x1F)
          run((condition << 28) | 0x03A0_0001) # mov r0, #1
          regs[0] == 1
        end

        expect(ran).to eq((0..15).select { mask[it] == 1 })
      end
    end

    # Thumb add r0, r1, r2, sub r0, r1, r2, adc r0, r1 and sbc r0, r1, with the registers from r0, the flags NZCV
    # before, the result and the flags after
    {
      'add that carries out to 0' => [0x1888, [0, 0xFFFF_FFFF, 1], 0b0001, 0, 0b0110],
      'add that stops short of a carry' => [0x1888, [0, 0xFFFF_FFFE, 1], 0b0011, 0xFFFF_FFFF, 0b1000],
      'add that overflows' => [0x1888, [0, 0x7FFF_FFFF, 1], 0b0000, 0x8000_0000, 0b1001],
      'adc with the carry set' => [0x4148, [1, 1], 0b0010, 3, 0b0000],
      'adc that stops short of a carry' => [0x4148, [0xFFFF_FFFE, 0], 0b0010, 0xFFFF_FFFF, 0b1000],
      'adc that overflows' => [0x4148, [0x7FFF_FFFF, 0], 0b0010, 0x8000_0000, 0b1001],
      'sub of equal values' => [0x1A88, [0, 5, 5], 0b0000, 0, 0b0110],
      'sub that borrows' => [0x1A88, [0, 0, 1], 0b0010, 0xFFFF_FFFF, 0b1000],
      'sub that overflows' => [0x1A88, [0, 0x8000_0000, 1], 0b0000, 0x7FFF_FFFF, 0b0011],
      'sbc with the carry clear' => [0x4188, [5, 3], 0b0000, 1, 0b0010],
      'sbc of equal values with the carry clear' => [0x4188, [3, 3], 0b0000, 0xFFFF_FFFF, 0b1000],
      'sbc that overflows' => [0x4188, [0x8000_0000, 1], 0b0010, 0x7FFF_FFFF, 0b0011]
    }.each do |name, (opcode, values, before, result, flags)|
      it "gives the result and the flags of a Thumb #{name}" do
        values.each_with_index { |value, i| regs[i] = value }
        cpu.instance_variable_set(:@cpsr, (before << 28) | 0x1F)
        run(opcode, thumb: true)

        expect([regs[0], cpsr >> 28]).to eq([result, flags])
      end
    end

    it 'reads r15 as the address of the instruction + 4 in Thumb' do
      run(0x4678, thumb: true) # mov r0, pc

      expect(regs[0]).to eq(base + 4)
    end

    [0x0300_0000, 0x0300_0002].each do |address|
      context format('with a Thumb instruction at %08X', address) do
        let(:base) { address }

        it 'takes the word boundary at or before the instruction + 4 as the pc of a load and of an address' do
          bus.write32(0x0300_0008, 0x1234_5678)
          run(0x4801, thumb: true) # ldr r0, [pc, #4]
          loaded = regs[0]
          run(0xA001, thumb: true) # add r0, pc, #4

          expect([loaded, regs[0]]).to eq([0x1234_5678, 0x0300_0008])
        end
      end
    end

    { 'bne' => 0xD101, 'b' => 0xE001 }.each do |name, opcode|
      it "jumps from the address of the instruction + 4 with Thumb #{name}" do
        run(opcode, thumb: true) # by 2

        expect(regs[15]).to eq(base + 6)
      end
    end

    it 'works out lr from the address of the instruction + 4 in the first half of Thumb bl' do
      run(0xF001, thumb: true)

      expect(regs[14]).to eq(base + 4 + 0x1000)
    end

    it 'loads the registers of Thumb pop and ldmia' do
      bus.write32(0x0300_0100, 0x11)
      bus.write32(0x0300_0104, 0x22)
      regs[13] = 0x0300_0100
      regs[4] = 0x0300_0100
      run(0xBC03, thumb: true) # pop {r0, r1}
      run(0xCC0C, thumb: true) # ldmia r4!, {r2, r3}

      expect(regs[0, 5] + [regs[13]]).to eq([0x11, 0x22, 0x11, 0x22, 0x0300_0108, 0x0300_0108])
    end

    it 'stores the address of the instruction + 6 with a Thumb stmia of no registers' do
      regs[1] = 0x0300_0100
      run(0xC100, thumb: true) # stmia r1!, {}

      expect([bus.read32(0x0300_0100), regs[1]]).to eq([base + 6, 0x0300_0140])
    end

    it 'drops the low bits of an address written to r15' do
      bus.write32(base + 0x10, 0xE3A04009) # mov r4, #9
      regs[2] = base + 0x13
      run(0xE1A0F002) # mov pc, r2
      cpu.exec

      expect([regs[4], regs[15]]).to eq([9, base + 0x14])
    end

    it 'moves the base of stmdb down by a word for each register of the list' do
      regs[7] = 0x77
      regs[8] = 0x88
      regs[13] = 0x0300_0100

      run(0xE92D0180) # stmdb sp!, {r7, r8}

      expect([regs[13], bus.read32(0x0300_00F8), bus.read32(0x0300_00FC)]).to eq([0x0300_00F8, 0x77, 0x88])
    end

    describe 'multiply' do
      [
        [0xFFFF_FFFF, 0xFFFF_FFFF], [0x8000_0000, 0x8000_0000], [0x7FFF_FFFF, 0xFFFF_FFFF], [0x1234_5678, 0x9ABC_DEF0],
        [0x0001_FFFF, 0x0001_FFFF], [0xFFFF, 0x0001_0001], [0, 0xFFFF_FFFF]
      ].each do |x, y|
        context format('of %<x>#010x by %<y>#010x', x:, y:) do
          before do
            regs[0] = 0x5555_5555 # mul does not add what its Rn field names
            regs[1] = x
            regs[2] = y
            regs[3] = 0x89AB_CDEF
          end

          it 'gives the low word for mul, and adds a register for mla' do
            run(0xE0000291) # mul r0, r1, r2
            expect(regs[0]).to eq((x * y) & 0xFFFF_FFFF)

            run(0xE0203291) # mla r0, r1, r2, r3
            expect(regs[0]).to eq(((x * y) + 0x89AB_CDEF) & 0xFFFF_FFFF)
          end

          it 'gives the low word for the Thumb mul' do
            regs[0] = y
            run(0x4348, thumb: true) # mul r0, r1

            expect(regs[0]).to eq((x * y) & 0xFFFF_FFFF)
          end

          it 'gives both words for umull, and for smull with the signs' do
            run(0xE0854291) # umull r4, r5, r1, r2
            expect([regs[5], regs[4]]).to eq(words(x * y))

            run(0xE0C54291) # smull r4, r5, r1, r2
            expect([regs[5], regs[4]]).to eq(words(s32(x) * s32(y)))
          end

          [[0xFFFF_FFFF, 0xFFFF_FFFF], [0x1234_5678, 0x9ABC_DEF0], [0, 0]].each do |high, low|
            it format('adds the product to %<high>#010x %<low>08x for umlal and smlal', high:, low:) do
              regs[5] = high
              regs[4] = low
              run(0xE0A54291) # umlal r4, r5, r1, r2
              expect([regs[5], regs[4]]).to eq(words((x * y) + (high << 32) + low))

              regs[5] = high
              regs[4] = low
              run(0xE0E54291) # smlal r4, r5, r1, r2
              expect([regs[5], regs[4]]).to eq(words((s32(x) * s32(y)) + (high << 32) + low))
            end
          end
        end
      end

      {
        'umulls of 1 by 1' => [0xE0954291, 1, 1, [0, 0]],
        'umulls of 0x10000 by 0x10000, where only the low word is 0' => [0xE0954291, 0x1_0000, 0x1_0000, [0, 0]],
        'umulls of 0 by 5' => [0xE0954291, 0, 5, [0, 1]],
        'umulls of 0xffffffff by itself, where bit 31 of the low word is clear' => [0xE0954291, 0xFFFF_FFFF, 0xFFFF_FFFF, [1, 0]],
        'smulls of -1 by 1' => [0xE0D54291, 0xFFFF_FFFF, 1, [1, 0]],
        'smulls of -1 by -1' => [0xE0D54291, 0xFFFF_FFFF, 0xFFFF_FFFF, [0, 0]]
      }.each do |name, (opcode, x, y, flags)|
        it "sets N and Z to #{flags.join(' and ')} for #{name}" do
          regs[1] = x
          regs[2] = y
          run(opcode)

          expect([cpsr[31], cpsr[30]]).to eq(flags)
        end
      end
    end

    describe 'a shift by a register' do
      # The result and the carry, as shifts of numbers of any size give them
      def wide(shift, x, n)
        case shift
        when 'lsl' then [(x << n) & 0xFFFF_FFFF, (x << n)[32]]
        when 'lsr' then [x >> n, x[n - 1]]
        when 'asr' then [(s32(x) >> n) & 0xFFFF_FFFF, s32(x)[n - 1]]
        when 'ror'
          result = ((x >> (n % 32)) | (x << (32 - (n % 32)))) & 0xFFFF_FFFF
          [result, result[31]]
        end
      end

      { 'lsl' => 0xE1B00211, 'lsr' => 0xE1B00231, 'asr' => 0xE1B00251, 'ror' => 0xE1B00271 }.each do |shift, opcode|
        [1, 2, 31, 32, 33, 63, 64, 65, 255].each do |n|
          it "gives the result and the carry of #{shift} by #{n}" do
            values = [0x8000_0001, 0x7FFF_FFFE, 0xFFFF_FFFF, 0x4000_0002, 1]
            got = values.map do |x|
              regs[1] = x
              regs[2] = n
              run(opcode) # movs r0, r1, <shift> r2
              [regs[0], cpsr[29]]
            end

            expect(got).to eq(values.map { wide(shift, it, n) })
          end
        end
      end
    end

    describe 'r8 to r12' do
      def switch_to(mode)
        regs[0] = mode
        run(0xE129F000) # msr cpsr_fc, r0
      end

      it 'has a set of its own in FIQ mode and one that the other modes share' do
        5.times { |i| regs[8 + i] = 0x100 + i }
        switch_to(0x11) # FIQ
        expect(regs[8, 5]).to eq([0] * 5)

        5.times { |i| regs[8 + i] = 0x200 + i }
        switch_to(0x12) # IRQ
        expect(regs[8, 5]).to eq([0x100, 0x101, 0x102, 0x103, 0x104])

        switch_to(0x1F) # System
        expect([regs[7], regs[8, 5]]).to eq([0, [0x100, 0x101, 0x102, 0x103, 0x104]])

        switch_to(0x11)
        expect(regs[8, 5]).to eq([0x200, 0x201, 0x202, 0x203, 0x204])
      end
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
