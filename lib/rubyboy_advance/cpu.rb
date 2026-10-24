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
      @spsrs = { usr: 0, fiq: 0, irq: 0, svc: 0, abt: 0, und: 0 }
      @banked_regs = { usr: Array.new(5, 0), fiq: Array.new(5, 0) }
      @sps = { usr: 0, fiq: 0, irq: 0, svc: 0, abt: 0, und: 0 }
      @lrs = { usr: 0, fiq: 0, irq: 0, svc: 0, abt: 0, und: 0 }
      @bus = bus
    end

    def exec
      address = pc

      if flag_t
        opcode = @bus.read16(address)
        self.pc += 2

        if opcode >> 13 == 0b001
          nn = opcode[0..7]
          rd = opcode[8..10]
          case opcode[11..12]
          when 0b00
            @regs[rd] = nn
            self.flag_z = nn == 0
            self.flag_n = nn[31] == 1
          when 0b01
            sub(reg(rd), nn)
          when 0b10
            @regs[rd] = add(reg(rd), nn)
          when 0b11
            @regs[rd] = sub(reg(rd), nn)
          end
        elsif opcode >> 10 == 0b010001
          rd = opcode[7] << 3 | opcode[0..2]
          rs = (opcode[6] << 3) | opcode[3..5]

          case opcode[8..9]
          when 0b00
            @regs[rd] = (reg(rd) + reg(rs)) & 0xFFFF_FFFF
          when 0b01
            sub(reg(rd), reg(rs))
          when 0b10
            @regs[rd] = reg(rs)
          when 0b11
            bx(reg(rs))
          end
        elsif opcode >> 12 == 0b1010
          rd = opcode[8..10]
          nn = opcode[0..7]
          @regs[rd] = (opcode[11] == 0 ? reg(15) & ~2 : sp) + (nn << 2)
        else
          raise format('Unknown Thumb instruction %<opcode>04X at %<address>08X', opcode:, address:)
        end

        return 1
      end

      opcode = @bus.read32(address)
      self.pc += 4
      return 1 unless executable?(opcode)

      instruction = determine_instruction(opcode)
      case instruction
      when :branch_and_exchange
        rn_index = opcode[0..3]
        rn = reg(rn_index)
        bx(rn)
      when :block_data_transfer
        rlist = opcode[0..15]
        n = 16.times.count { |i| rlist[i] == 1 }
        rn_index = opcode[16..19]
        rn = @regs[rn_index]
        start_address =
          if opcode[24] == 0
            opcode[23] == 0 ? rn - (n << 2) + 4 : rn
          else
            opcode[23] == 0 ? rn - (n << 2) : rn + 4
          end

        current_address = start_address
        16.times do |i|
          next unless rlist[i] == 1

          if opcode[20] == 0
            @bus.write32(current_address, @regs[i])
          else
            @regs[i] = @bus.read32(current_address)
          end

          current_address += 4
        end

        @regs[rn_index] = opcode[23] == 0 ? rn - (n << 2) : rn + (n << 2) if opcode[21] == 1
      when :data_processing
        s = opcode[20] == 1
        rn_index = opcode[16..19]
        rn = reg(rn_index)
        @shifter_carry = nil
        op2 = if opcode[25] == 0
                r = opcode[4]
                n = r == 0 ? opcode[7..11] : reg(opcode[8..11]) & 0xFF
                rm_index = opcode[0..3]
                x = reg(rm_index)
                if r == 1
                  rn += 4 if rn_index == 15
                  x += 4 if rm_index == 15
                end
                case opcode[5..6]
                when 0b00
                  lsl(x, n, s:)
                when 0b01
                  n = 32 if r == 0 && n == 0
                  lsr(x, n, s:)
                when 0b10
                  n = 32 if r == 0 && n == 0
                  asr(x, n, s:)
                when 0b11
                  r == 0 && n == 0 ? rrx(x, s:) : ror(x, n, s:)
                end
              else
                n = opcode[8..11] * 2
                x = opcode[0..7]
                ror(x, n, s:)
              end
        code = opcode[21..24]
        result =
          case code
          when 0x00, 0x08 then rn & op2
          when 0x01, 0x09 then rn ^ op2
          when 0x02, 0x0A
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
          when 0x04, 0x0B
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
          when 0x0C then rn | op2
          when 0x0D then op2
          when 0x0E then rn & ~op2
          when 0x0F then ~op2
          end & 0xFFFF_FFFF

        rd = opcode[12..15]
        if s
          if rd == 15
            tmp = spsr(current_cpu_mode)
            update_banked_regs(to_cpu_mode(tmp))
            @cpsr = tmp
          else
            unless @shifter_carry.nil?
              case code
              when 0x00, 0x01, 0x08, 0x09, 0x0C, 0x0D, 0x0E, 0x0F
                self.flag_c = @shifter_carry
              end
            end
            self.flag_z = result == 0
            self.flag_n = result[31] == 1
          end
        end

        case code
        when 0x08, 0x09, 0x0A, 0x0B
          return 1
        end

        @regs[rd] = result

      when :single_data_transfer
        offset =
          if opcode[25] == 0
            opcode[0..11]
          else
            rm = reg(opcode[0..3])
            shift_amount = opcode[7..11]
            case opcode[5..6]
            when 0b00 then lsl(rm, shift_amount)
            when 0b01 then shift_amount == 0 ? lsr(rm, 32) : lsr(rm, shift_amount)
            when 0b10 then shift_amount == 0 ? asr(rm, 32) : asr(rm, shift_amount)
            when 0b11 then shift_amount == 0 ? rrx(rm) : ror(rm, shift_amount)
            end
          end
        transfer(opcode, offset) do |addr|
          if opcode[20] == 1
            @regs[opcode[12..15]] = opcode[22] == 0 ? @bus.read32(addr) : @bus.read(addr)
          else
            opcode[22] == 0 ? @bus.write32(addr, reg(opcode[12..15])) : @bus.write(addr, reg(opcode[12..15]) & 0xFF)
          end
        end
      when :multiply
        case opcode[21]
        when 0
          result = (reg(opcode[0..3]) * reg(opcode[8..11])) & 0xFFFF_FFFF
        when 1
          result = (reg(opcode[0..3]) * reg(opcode[8..11]) + reg(opcode[12..15])) & 0xFFFF_FFFF
        end

        if opcode[20] == 1
          self.flag_z = result == 0
          self.flag_n = result[31] == 1
        end

        @regs[opcode[16..19]] = result

      when :multiply_long
        result = opcode[22] == 0 ? (reg(opcode[0..3]) * reg(opcode[8..11])) : (uint_to_int(reg(opcode[0..3])) * uint_to_int(reg(opcode[8..11])))

        result += (reg(opcode[16..19]) << 32) | reg(opcode[12..15]) if opcode[21] == 1
        result &= 0xFFFF_FFFF_FFFF_FFFF

        @regs[opcode[16..19]] = result >> 32
        @regs[opcode[12..15]] = result & 0xFFFF_FFFF

        if opcode[20] == 1
          self.flag_z = result == 0
          self.flag_n = result[63] == 1
        end
      when :halfword_data_transfer
        offset = opcode[22] == 0 ? reg(opcode[0..3]) : (opcode[8..11] << 4) | opcode[0..3]
        transfer(opcode, offset) do |addr|
          case (opcode[20] << 2) | opcode[5..6]
          when 0b001
            @bus.write16(addr, reg(opcode[12..15]) & 0xFFFF)
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

        self.pc = reg(15) + (offset << 2)
      when :software_interrupt
        case opcode[16..23]
        when 6
          raise 'Division by zero' if @regs[1] == 0

          regs0 = uint_to_int(@regs[0])
          regs1 = uint_to_int(@regs[1])

          rem = regs0.remainder(regs1)
          @regs[0] = int_to_uint((regs0 - rem) / regs1)
          @regs[1] = int_to_uint(rem)
          @regs[3] = (regs0.abs / regs1.abs)
        else
          raise format('Unknown software interrupt %<opcode>08X at %<address>08X', opcode:, address:)
        end
      when :mrs then @regs[opcode[12..15]] = opcode[22] == 0 ? @cpsr : spsr(current_cpu_mode)
      when :msr
        x = opcode[25] == 0 ? reg(opcode[0..3]) : ror(opcode[0..7], opcode[8..11] * 2)
        mask = 0xFF000000 * opcode[19] | 0x00FF0000 * opcode[18] | 0x0000FF00 * opcode[17] | 0x000000FF * opcode[16]

        if opcode[22] == 0
          result = (@cpsr & ~mask) | (x & mask)
          update_banked_regs(to_cpu_mode(result))
          @cpsr = result
        else
          mode = current_cpu_mode
          @spsrs[mode] = (@spsrs[mode] & ~mask) | (x & mask)
        end
      else
        raise format('Unknown opcode %<opcode>08X at %<address>08X', opcode:, address:)
      end
      # TODO: Implement proper cycle counting and other side effects for each instruction.
      1
    end

    private

    def current_cpu_mode
      to_cpu_mode(@cpsr)
    end

    def spsr(mode)
      mode == :usr ? @cpsr : @spsrs[mode]
    end

    def sys_mode?
      @cpsr & 0x1F == 0x1F
    end

    def to_cpu_mode(value)
      case value & 0x1F
      when 0x10, 0x1F then :usr
      when 0x11 then :fiq
      when 0x12 then :irq
      when 0x13 then :svc
      when 0x17 then :abt
      when 0x1B then :und
      else raise "Unknown CPU mode: #{value & 0x1F}"
      end
    end

    def banked_regs_by_mode(mode)
      case mode
      when :fiq then @banked_regs[:fiq]
      else @banked_regs[:usr]
      end
    end

    def set_banked_regs_by_mode(mode, value)
      case mode
      when :fiq then @banked_regs[:fiq] = value
      else @banked_regs[:usr] = value
      end
    end

    def update_banked_regs(new_mode)
      current_mode = current_cpu_mode

      return if new_mode == current_mode

      @sps[current_mode] = sp
      self.sp = @sps[new_mode]

      @lrs[current_mode] = lr
      self.lr = @lrs[new_mode]

      set_banked_regs_by_mode(current_mode, @regs[8..12])
      @regs[8..12] = banked_regs_by_mode(new_mode)
    end

    def int_to_uint(n)
      n & 0xFFFF_FFFF
    end

    def uint_to_int(n)
      n[31] == 1 ? n - 0x1_0000_0000 : n
    end

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

    # Reads a register as an instruction operand. pc already points past the
    # current instruction (by 4 in ARM, 2 in Thumb), but r15 reads as the
    # instruction's address + 8 in ARM and + 4 in Thumb.
    def reg(index)
      return @regs[index] if index != 15

      @regs[15] + (flag_t ? 2 : 4)
    end

    def flag_t
      @cpsr[5] == 1
    end

    def flag_t=(value)
      @cpsr = value ? @cpsr | (1 << 5) : @cpsr & ~(1 << 5)
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

    def add(x, y)
      tmp = x + y
      result = tmp & 0xFFFF_FFFF
      self.flag_z = result == 0
      self.flag_n = result[31] == 1
      self.flag_c = (tmp > 0xFFFF_FFFF)
      self.flag_v = ((x ^ result) & (y ^ result))[31] == 1

      result
    end

    def sub(x, y)
      result = (x - y) & 0xFFFF_FFFF
      self.flag_z = result == 0
      self.flag_n = result[31] == 1
      self.flag_c = (x >= y)
      self.flag_v = ((x ^ y) & (x ^ result))[31] == 1

      result
    end

    def lsl(x, n, s: false)
      return x if n == 0

      result = (x << n)
      @shifter_carry = result[32] == 1 if s
      result & 0xFFFF_FFFF
    end

    def lsr(x, n, s: false)
      return x if n == 0

      @shifter_carry = x[n - 1] == 1 if s
      (x >> n) & 0xFFFF_FFFF
    end

    def asr(x, n, s: false)
      return x if n == 0

      @shifter_carry = uint_to_int(x)[n - 1] == 1 if s
      (uint_to_int(x) >> n) & 0xFFFF_FFFF
    end

    def ror(x, n, s: false)
      return x if n == 0

      result = ((x >> (n & 0x1F)) | (x << (32 - (n & 0x1F)))) & 0xFFFF_FFFF
      @shifter_carry = result[31] == 1 if s

      result
    end

    def rrx(x, s: false)
      @shifter_carry = x[0] == 1 if s
      ((x >> 1) | (@cpsr[29] << 31)) & 0xFFFF_FFFF
    end

    def bx(rn)
      self.pc = if rn[0] == 1
                  self.flag_t = true
                  rn & ~1
                else
                  self.flag_t = false
                  rn & ~3
                end
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
      rn_index = opcode[16..19]
      offset_addr = (opcode[23] == 1 ? reg(rn_index) + offset : reg(rn_index) - offset) & 0xFFFF_FFFF
      yield(opcode[24] == 1 ? offset_addr : reg(rn_index))
      @regs[rn_index] = offset_addr if opcode[24] == 0 || opcode[21] == 1
    end

    def determine_instruction(opcode)
      INSTRUCTION_TABLE[opcode[20..27] << 4 | opcode[4..7]]
    end
  end
end
