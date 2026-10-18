# frozen_string_literal: true

module RubyboyAdvance
  class Cpu
    INSTRUCTION_TABLE = Array.new(0x1000) do |i|
      if i == 0b000100100001 then :branch_and_exchange
      elsif i[9..11] == 0b100 then :block_data_transfer
      elsif i[9..11] == 0b101 then :branch
      elsif i[8..11] == 0b1111 then :software_interrupt
      elsif i[9..11] == 0b011 && i[0] == 1 then :undefined
      elsif i[10..11] == 0b01 then :single_data_transfer
      elsif i[7..11] == 0b00010 && i[0..3] == 0b1001 then :single_data_swap
      elsif i[7..11] == 0b00000 && i[0..3] == 0b1001 then :multiply
      elsif i[7..11] == 0b00001 && i[0..3] == 0b1001 then :multiply_long
      elsif i[9..11] == 0b000 && i[3] == 1 && i[0] == 1 then :halfword_data_transfer
      elsif i[7..11] == 0b00010 && i[4..5] == 0b00 then :mrs
      elsif i[10..11] == 0b00 && i[7..8] == 0b10 && i[4..5] == 0b10 then :msr
      elsif i[10..11] == 0b00 then :data_processing
      else :unknown
      end
    end.freeze

    def initialize(bus)
      @regs = Array.new(16, 0)
      self.sp = 0x0300_7F00
      self.pc = 0x0800_0000
      @cpsr = 0x1F
      @bus = bus
    end

    def exec
      address = pc
      opcode = @bus.read32(address)
      self.pc += 4
      return 1 unless executable?(opcode)

      instruction = determine_instruction(opcode)
      case instruction
      when :data_processing
        s = opcode[20] == 1
        rn = @regs[opcode[16..19]]
        op2 = if opcode[25] == 0
                raise format('TODO %<opcode>08X at %<address>08X', opcode:, address:)
              else
                n = opcode[8..11] * 2
                x = opcode[0..7]
                ((x >> n) | (x << (32 - n))) & 0xFFFF_FFFF
              end

        result =
          case opcode[21..24]
          when 0x00 then rn & op2
          when 0x01 then rn ^ op2
          when 0x02
            tmp = rn - op2
            if s
              self.flag_c = (rn >= op2)
              self.flag_v = ((rn ^ op2) & (rn ^ tmp))[31] == 1
            end

            tmp
          when 0x03
            tmp = op2 - rn
            if s
              self.flag_c = (op2 >= rn)
              self.flag_v = ((op2 ^ rn) & (op2 ^ tmp))[31] == 1
            end

            tmp
          when 0x04
            tmp = rn + op2
            if s
              self.flag_c = (tmp > 0xFFFF_FFFF)
              self.flag_v = ((rn ^ tmp) & (op2 ^ tmp))[31] == 1
            end

            tmp
          when 0x05
            tmp = rn + op2 + (flag_c ? 1 : 0)
            if s
              self.flag_c = (tmp > 0xFFFF_FFFF)
              self.flag_v = ((rn ^ tmp) & (op2 ^ tmp))[31] == 1
            end

            tmp
          when 0x06
            tmp = rn - op2 - (flag_c ? 0 : 1)
            if s
              self.flag_c = (rn >= op2 + (flag_c ? 0 : 1))
              self.flag_v = ((rn ^ op2) & (rn ^ tmp))[31] == 1
            end

            tmp
          when 0x07
            tmp = op2 - rn - (flag_c ? 0 : 1)
            if s
              self.flag_c = (op2 >= rn + (flag_c ? 0 : 1))
              self.flag_v = ((op2 ^ rn) & (op2 ^ tmp))[31] == 1
            end

            tmp
          when 0x08
            tmp = rn & op2
            if s
              self.flag_z = (tmp & 0xFFFF_FFFF == 0)
              self.flag_n = tmp[31] == 1
            end

            return 1
          when 0x09
            tmp = rn ^ op2
            if s
              self.flag_z = (tmp & 0xFFFF_FFFF == 0)
              self.flag_n = tmp[31] == 1
            end

            return 1
          when 0x0A
            tmp = rn - op2
            if s
              self.flag_z = (tmp & 0xFFFF_FFFF == 0)
              self.flag_n = tmp[31] == 1
              self.flag_c = (rn >= op2)
              self.flag_v = ((rn ^ op2) & (rn ^ tmp))[31] == 1
            end

            return 1
          when 0x0B
            tmp = rn + op2
            if s
              self.flag_z = (tmp & 0xFFFF_FFFF == 0)
              self.flag_n = tmp[31] == 1
              self.flag_c = (tmp > 0xFFFF_FFFF)
              self.flag_v = ((rn ^ tmp) & (op2 ^ tmp))[31] == 1
            end

            return 1
          when 0x0C then rn | op2
          when 0x0D then op2
          when 0x0E then rn & ~op2
          when 0x0F then ~op2
          end & 0xFFFF_FFFF

        if s
          self.flag_z = result == 0
          self.flag_n = result[31] == 1
        end

        @regs[opcode[12..15]] = result
      when :single_data_transfer
        offset = opcode[25] == 0 ? opcode[0..11] : raise(format('TODO %<opcode>08X at %<address>08X', opcode:, address:))
        transfer(opcode, offset) do |addr|
          if opcode[20] == 1
            @regs[opcode[12..15]] = opcode[22] == 0 ? @bus.read32(addr) : @bus.read(addr)
          else
            opcode[22] == 0 ? @bus.write32(addr, @regs[opcode[12..15]]) : @bus.write(addr, @regs[opcode[12..15]] & 0xFF)
          end
        end
      when :halfword_data_transfer
        offset = opcode[22] == 0 ? @regs[opcode[0..3]] : (opcode[8..11] << 4) | opcode[0..3]
        transfer(opcode, offset) do |addr|
          case (opcode[20] << 2) | opcode[5..6]
          when 0b001
            @bus.write16(addr, @regs[opcode[12..15]] & 0xFFFF)
          when 0b101
            @regs[opcode[12..15]] = @bus.read16(addr)
          when 0b110
            v = @bus.read(addr)
            @regs[opcode[12..15]] = v[7] == 1 ? v | 0xFFFF_FF00 : v
          when 0b111
            v = @bus.read16(addr)
            @regs[opcode[12..15]] = v[15] == 1 ? v | 0xFFFF_0000 : v
          else
            raise format('Unknown halfword transfer opcode %<opcode>08X at %<address>08X', opcode:, address:)
          end
        end
      when :branch
        offset = opcode[0..23]
        offset -= 0x100_0000 if offset[23] == 1
        self.lr = pc if opcode[24] == 1

        self.pc = pc + 4 + (offset << 2)
      else
        raise format('Unknown opcode %<opcode>08X at %<address>08X', opcode:, address:)
      end
      # TODO: Implement proper cycle counting and other side effects for each instruction.
      1
    end

    private

    def sp
      @regs[13]
    end

    def sp=(value)
      @regs[13] = value
    end

    def lr
      @regs[14]
    end

    def lr=(value)
      @regs[14] = value
    end

    def pc
      @regs[15]
    end

    def pc=(value)
      @regs[15] = value
    end

    def flag_z
      @cpsr[30] == 1
    end

    def flag_z=(value)
      @cpsr = value ? @cpsr | (1 << 30) : @cpsr & ~(1 << 30)
    end

    def flag_n
      @cpsr[31] == 1
    end

    def flag_n=(value)
      @cpsr = value ? @cpsr | (1 << 31) : @cpsr & ~(1 << 31)
    end

    def flag_c
      @cpsr[29] == 1
    end

    def flag_c=(value)
      @cpsr = value ? @cpsr | (1 << 29) : @cpsr & ~(1 << 29)
    end

    def flag_v
      @cpsr[28] == 1
    end

    def flag_v=(value)
      @cpsr = value ? @cpsr | (1 << 28) : @cpsr & ~(1 << 28)
    end

    def executable?(opcode)
      case opcode >> 28
      when 0x0 then flag_z
      when 0x1 then !flag_z
      when 0x2 then flag_c
      when 0x3 then !flag_c
      when 0x4 then flag_n
      when 0x5 then !flag_n
      when 0x6 then flag_v
      when 0x7 then !flag_v
      when 0x8 then flag_c && !flag_z
      when 0x9 then !flag_c || flag_z
      when 0xA then flag_n == flag_v
      when 0xB then flag_n != flag_v
      when 0xC then !flag_z && (flag_n == flag_v)
      when 0xD then flag_z || (flag_n != flag_v)
      when 0xE then true
      else false
      end
    end

    def transfer(opcode, offset)
      rn = opcode[16..19]
      offset_addr = (opcode[23] == 1 ? @regs[rn] + offset : @regs[rn] - offset) & 0xFFFF_FFFF
      yield(opcode[24] == 1 ? offset_addr : @regs[rn])
      @regs[rn] = offset_addr if opcode[24] == 0 || opcode[21] == 1
    end

    def determine_instruction(opcode)
      INSTRUCTION_TABLE[opcode[20..27] << 4 | opcode[4..7]]
    end
  end
end
