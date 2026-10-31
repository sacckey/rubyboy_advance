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
      @sps = { usr: 0, fiq: 0, irq: 0x0300_7FA0, svc: 0x0300_7FE0, abt: 0, und: 0 }
      @lrs = { usr: 0, fiq: 0, irq: 0, svc: 0, abt: 0, und: 0 }
      @bus = bus
      @interrupt = @bus.interrupt
    end

    def exec
      # Writes to r15 keep whatever value they were given; the CPU ignores the
      # low bits, so align PC here once instead of at every instruction that sets it.
      self.pc &= flag_t ? ~1 : ~3

      if @interrupt.irq? && @cpsr[7] == 0
        @spsrs[:irq] = @cpsr
        update_banked_regs(:irq)
        self.lr = pc + 4
        @cpsr = (@cpsr & ~0x3F) | 0x80 | 0x12
        self.pc = 0x18
        return 1
      end

      address = pc

      if flag_t
        opcode = @bus.read16(address)
        self.pc += 2

        case opcode >> 12
        when 0x0, 0x1
          rs = reg(opcode[3..5])
          rd_index = opcode[0..2]

          case opcode[11..12]
          when 0b11
            # Format 2: Add / subtract
            immediate_value = opcode[6..8]

            case opcode[9..10]
            when 0b00 then @regs[rd_index] = add(rs, reg(immediate_value))
            when 0b01 then @regs[rd_index] = sub(rs, reg(immediate_value))
            when 0b10 then @regs[rd_index] = add(rs, immediate_value)
            when 0b11 then @regs[rd_index] = sub(rs, immediate_value)
            end
          else
            # Format 1: Move shifted register (LSL, LSR, ASR)
            offset = opcode[6..10]
            @shifter_carry = nil

            case opcode[11..12]
            when 0b00 then @regs[rd_index] = lsl(rs, offset, s: true)
            when 0b01
              offset = 32 if offset == 0
              @regs[rd_index] = lsr(rs, offset, s: true)
            when 0b10
              offset = 32 if offset == 0
              @regs[rd_index] = asr(rs, offset, s: true)
            end

            update_nz(@regs[rd_index])
            self.flag_c = @shifter_carry unless @shifter_carry.nil?
          end
        when 0x2, 0x3
          # Format 3: Move / compare / add / subtract immediate
          nn = opcode[0..7]
          rd = opcode[8..10]
          case opcode[11..12]
          when 0b00
            @regs[rd] = nn
            update_nz(nn)
          when 0b01 then sub(reg(rd), nn)
          when 0b10 then @regs[rd] = add(reg(rd), nn)
          when 0b11 then @regs[rd] = sub(reg(rd), nn)
          end
        when 0x4
          case opcode[10..11]
          when 0b00
            # Format 4: ALU operations
            rs_index = opcode[3..5]
            rs = reg(rs_index)
            rd_index = opcode[0..2]
            rd = reg(rd_index)
            @shifter_carry = nil

            case opcode[6..9]
            when 0x0 then @regs[rd_index] = and32(rd, rs)
            when 0x1 then @regs[rd_index] = xor(rd, rs)
            when 0x2 then @regs[rd_index] = update_nz(lsl(rd, rs & 0xFF, s: true))
            when 0x3 then @regs[rd_index] = update_nz(lsr(rd, rs & 0xFF, s: true))
            when 0x4 then @regs[rd_index] = update_nz(asr(rd, rs & 0xFF, s: true))
            when 0x5 then @regs[rd_index] = adc(rd, rs)
            when 0x6 then @regs[rd_index] = sbc(rd, rs)
            when 0x7 then @regs[rd_index] = update_nz(ror(rd, rs & 0xFF, s: true))
            when 0x8 then and32(rd, rs)
            when 0x9 then @regs[rd_index] = sub(0, rs)
            when 0xA then sub(rd, rs)
            when 0xB then add(rd, rs)
            when 0xC then @regs[rd_index] = or32(rd, rs)
            when 0xD then @regs[rd_index] = mul(rd, rs)
            when 0xE then @regs[rd_index] = and32(rd, (~rs) & 0xFFFF_FFFF)
            when 0xF then @regs[rd_index] = xor(rs, 0xFFFF_FFFF)
            end

            self.flag_c = @shifter_carry unless @shifter_carry.nil?
          when 0b01
            # Format 5: Hi register operations / branch exchange
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
          else
            # Format 6: PC-relative load
            rd_index = opcode[8..10]
            offset = opcode[0..7] << 2

            @regs[rd_index] = @bus.read32((reg(15) & ~2) + offset)
          end
        when 0x5
          # Format 7/8: Load / store with register offset (bit 9: 0 = format 7, 1 = format 8 sign-extended)
          ro_index = opcode[6..8]
          rb_index = opcode[3..5]
          rd_index = opcode[0..2]
          addr = (reg(rb_index) + reg(ro_index)) & 0xFFFF_FFFF

          if opcode[9] == 0
            case opcode[10..11]
            when 0b00
              @bus.write32(addr, reg(rd_index))
            when 0b01
              @bus.write(addr, reg(rd_index) & 0xFF)
            when 0b10
              @regs[rd_index] = ldr(addr)
            when 0b11
              @regs[rd_index] = @bus.read(addr)
            end
          else
            case opcode[10..11]
            when 0b00
              @bus.write16(addr, reg(rd_index) & 0xFFFF)
            when 0b01
              @regs[rd_index] = ldrsb(addr)
            when 0b10
              @regs[rd_index] = ldrh(addr)
            when 0b11
              @regs[rd_index] = ldrsh(addr)
            end
          end
        when 0x6, 0x7
          # Format 9: Load / store with immediate offset
          rb_index = opcode[3..5]
          rd_index = opcode[0..2]
          offset = opcode[6..10]
          offset <<= 2 if opcode[12] == 0

          addr = reg(rb_index) + offset

          case opcode[11..12]
          when 0b00
            @bus.write32(addr, reg(rd_index))
          when 0b01
            @regs[rd_index] = ldr(addr)
          when 0b10
            @bus.write(addr, reg(rd_index) & 0xFF)
          when 0b11
            @regs[rd_index] = @bus.read(addr)
          end
        when 0x8
          # Format 10: Load / store halfword
          rb_index = opcode[3..5]
          rd_index = opcode[0..2]
          offset = opcode[6..10] << 1

          addr = reg(rb_index) + offset

          if opcode[11] == 0
            @bus.write16(addr, reg(rd_index) & 0xFFFF)
          else
            @regs[rd_index] = ldrh(addr)
          end
        when 0x9
          # Format 11: SP-relative load / store
          rd_index = opcode[8..10]
          offset = opcode[0..7] << 2

          addr = sp + offset

          if opcode[11] == 0
            @bus.write32(addr, reg(rd_index))
          else
            @regs[rd_index] = ldr(addr)
          end
        when 0xA
          # Format 12: Load address
          rd = opcode[8..10]
          nn = opcode[0..7]
          @regs[rd] = (opcode[11] == 0 ? reg(15) & ~2 : sp) + (nn << 2)
        when 0xB
          case opcode[8..11]
          when 0b0000
            # Format 13: Add offset to stack pointer
            offset = opcode[0..6] << 2
            self.sp = (opcode[7] == 0 ? sp + offset : sp - offset) & 0xFFFF_FFFF
          when 0b0100, 0b0101, 0b1100, 0b1101
            # Format 14: Push / pop registers
            rlist = opcode[0..7]
            is_push = opcode[11] == 0
            n = 8.times.count { |i| rlist[i] == 1 }
            n += 1 if opcode[8] == 1

            start_address = is_push ? sp - (n << 2) : sp
            current_address = start_address
            8.times do |i|
              next unless rlist[i] == 1

              if is_push
                @bus.write32(current_address, reg(i))
              else
                @regs[i] = @bus.read32(current_address)
              end
              current_address += 4
            end

            if opcode[8] == 1
              if is_push
                @bus.write32(current_address, reg(14))
              else
                @regs[15] = @bus.read32(current_address)
              end
            end

            self.sp = is_push ? start_address : sp + (n << 2)
          end
        when 0xC
          # Format 15: Multiple load / store
          rlist = opcode[0..7]
          is_load = opcode[11] == 1
          n = 8.times.count { |i| rlist[i] == 1 }
          rb_index = opcode[8..10]
          rb = reg(rb_index)

          current_address = rb
          new_rb = rb + (n << 2)
          is_first = true
          if n == 0
            if is_load then @regs[15] = @bus.read32(current_address)
            else @bus.write32(current_address, reg(15) + 2)
            end
            new_rb = rb + 0x40
          else
            8.times do |i|
              next unless rlist[i] == 1

              if is_load
                @regs[i] = @bus.read32(current_address)
              else
                write_value = if i != rb_index
                                reg(i)
                              elsif is_first
                                rb
                              else
                                new_rb
                              end
                @bus.write32(current_address, write_value)
              end

              current_address += 4
              is_first = false
            end
          end

          @regs[rb_index] = new_rb if !is_load || rlist[rb_index] == 0
        when 0xD
          case opcode[8..11]
          when 0xE
            raise format('Unknown Thumb instruction %<opcode>04X at %<address>08X', opcode:, address:)
          when 0xF
            # Format 17: Software interrupt
            swi
          else
            return 1 unless executable?(opcode[8..11])

            offset = opcode[0..7]
            offset -= 0x100 if offset[7] == 1
            self.pc = reg(15) + (offset << 1)
          end
        when 0xE
          case opcode[11]
          when 0
            # Format 18: Unconditional branch
            offset = opcode[0..10]
            offset -= 0x800 if offset[10] == 1
            self.pc = reg(15) + (offset << 1)
          else
            raise format('Unknown Thumb instruction %<opcode>04X at %<address>08X', opcode:, address:)
          end
        when 0xF
          # Format 19: Long branch with link. The two halves are separate instructions linked through LR
          offset = opcode[0..10]
          if opcode[11] == 0
            offset -= 0x800 if offset[10] == 1
            self.lr = (reg(15) + (offset << 12)) & 0xFFFF_FFFF
          else
            target = (lr + (offset << 1)) & 0xFFFF_FFFF
            self.lr = pc | 1
            self.pc = target
          end
        end

        return 1
      end

      opcode = @bus.read32(address)
      self.pc += 4
      return 1 unless executable?(opcode >> 28)

      instruction = determine_instruction(opcode)
      case instruction
      when :branch_and_exchange
        rn_index = opcode[0..3]
        rn = reg(rn_index)
        bx(rn)
      when :block_data_transfer
        rlist = opcode[0..15]
        is_load = opcode[20] == 1
        n = 16.times.count { |i| rlist[i] == 1 }
        multiplicand = n == 0 ? 16 : n
        rn_index = opcode[16..19]
        rn = @regs[rn_index]
        from = current_cpu_mode

        update_banked_regs(:usr) if opcode[22] == 1 && (!is_load || rlist[15] == 0)

        start_address =
          if opcode[24] == 0
            opcode[23] == 0 ? rn - (multiplicand << 2) + 4 : rn
          else
            opcode[23] == 0 ? rn - (multiplicand << 2) : rn + 4
          end

        current_address = start_address
        new_rn = opcode[23] == 0 ? rn - (multiplicand << 2) : rn + (multiplicand << 2)
        is_first = true
        if n == 0
          if is_load then @regs[15] = @bus.read32(current_address)
          else @bus.write32(current_address, reg(15) + 4)
          end
        else
          16.times do |i|
            next unless rlist[i] == 1

            if is_load
              @regs[i] = @bus.read32(current_address)
            else
              write_value = if i == rn_index && !is_first && opcode[21] == 1
                              new_rn
                            else
                              i == 15 ? reg(i) + 4 : reg(i)
                            end
              @bus.write32(current_address, write_value)
            end

            current_address += 4
            is_first = false
          end
        end

        @regs[rn_index] = new_rn if opcode[21] == 1 && (!is_load || rlist[rn_index] == 0)

        if opcode[22] == 1
          if !is_load || rlist[15] == 0
            update_banked_regs(from, :usr)
          else
            tmp = spsr(current_cpu_mode)
            update_banked_regs(to_cpu_mode(tmp))
            @cpsr = tmp
          end
        end

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
            update_nz(result)
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
          rd = opcode[12..15]
          if opcode[20] == 1
            @regs[rd] = opcode[22] == 0 ? ldr(addr) : @bus.read(addr)
          else
            value = rd == 15 ? reg(rd) + 4 : reg(rd)
            opcode[22] == 0 ? @bus.write32(addr, value) : @bus.write(addr, value & 0xFF)
          end
        end
      when :single_data_swap
        rn_index = opcode[16..19]
        rm_index = opcode[0..3]
        rd_index = opcode[12..15]
        is_byte = opcode[22] == 1

        addr = reg(rn_index)
        write_value = reg(rm_index)
        read_value = is_byte ? @bus.read(addr) : ldr(addr)
        is_byte ? @bus.write(addr, write_value & 0xFF) : @bus.write32(addr, write_value)
        @regs[rd_index] = read_value

      when :multiply
        case opcode[21]
        when 0
          result = (reg(opcode[0..3]) * reg(opcode[8..11])) & 0xFFFF_FFFF
        when 1
          result = (reg(opcode[0..3]) * reg(opcode[8..11]) + reg(opcode[12..15])) & 0xFFFF_FFFF
        end

        update_nz(result) if opcode[20] == 1

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
            rd = opcode[12..15]
            value = rd == 15 ? reg(rd) + 4 : reg(rd)
            @bus.write16(addr, value & 0xFFFF)
          when 0b101 then @regs[opcode[12..15]] = ldrh(addr)
          when 0b110 then @regs[opcode[12..15]] = ldrsb(addr)
          when 0b111 then @regs[opcode[12..15]] = ldrsh(addr)
          else
            raise format('Unknown halfword transfer opcode %<opcode>08X at %<address>08X', opcode:, address:)
          end
        end
      when :branch
        offset = opcode[0..23]
        offset -= 0x100_0000 if offset[23] == 1
        self.lr = pc if opcode[24] == 1

        self.pc = reg(15) + (offset << 2)
      when :software_interrupt then swi
      when :mrs then @regs[opcode[12..15]] = opcode[22] == 0 ? @cpsr : spsr(current_cpu_mode)
      when :msr
        x = opcode[25] == 0 ? reg(opcode[0..3]) : ror(opcode[0..7], opcode[8..11] * 2)
        mask = 0xFF000000 * opcode[19] | 0x00FF0000 * opcode[18] | 0x0000FF00 * opcode[17] | 0x000000FF * opcode[16]

        if opcode[22] == 0
          mask &= 0xFF00_0000 if user_mode? # User mode may only write the flags
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

    def swi
      @spsrs[:svc] = @cpsr
      update_banked_regs(:svc)
      self.lr = pc
      @cpsr = (@cpsr & ~0x3F) | 0x80 | 0x13
      self.pc = 0x08
    end

    def current_cpu_mode
      to_cpu_mode(@cpsr)
    end

    def spsr(mode)
      mode == :usr ? @cpsr : @spsrs[mode]
    end

    # User and System share :usr registers, so privilege checks look at the raw mode bits.
    def user_mode?
      @cpsr & 0x1F == 0x10
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

    def update_banked_regs(new_mode, from = current_cpu_mode)
      current_mode = from

      return if new_mode == current_mode

      @sps[current_mode] = sp
      self.sp = @sps[new_mode]

      @lrs[current_mode] = lr
      self.lr = @lrs[new_mode]

      set_banked_regs_by_mode(current_mode, @regs[8..12])
      @regs[8..12] = banked_regs_by_mode(new_mode)
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

    def update_nz(result)
      self.flag_z = result == 0
      self.flag_n = result[31] == 1

      result
    end

    def add(x, y)
      tmp = x + y
      result = tmp & 0xFFFF_FFFF
      update_nz(result)
      self.flag_c = (tmp > 0xFFFF_FFFF)
      self.flag_v = ((x ^ result) & (y ^ result))[31] == 1

      result
    end

    def adc(x, y)
      c = @cpsr[29]
      tmp = x + y + c
      result = tmp & 0xFFFF_FFFF
      update_nz(result)
      self.flag_c = (tmp > 0xFFFF_FFFF)
      self.flag_v = ((x ^ result) & (y ^ result))[31] == 1

      result
    end

    def sub(x, y)
      result = (x - y) & 0xFFFF_FFFF
      update_nz(result)
      self.flag_c = (x >= y)
      self.flag_v = ((x ^ y) & (x ^ result))[31] == 1

      result
    end

    def sbc(x, y)
      c = @cpsr[29]
      tmp = x - y - (1 - c)
      result = tmp & 0xFFFF_FFFF
      update_nz(result)
      self.flag_c = (x >= y + (1 - c))
      self.flag_v = ((x ^ y) & (x ^ result))[31] == 1

      result
    end

    def mul(x, y)
      update_nz((x * y) & 0xFFFF_FFFF)
    end

    def and32(x, y)
      update_nz(x & y)
    end

    def or32(x, y)
      update_nz(x | y)
    end

    def xor(x, y)
      update_nz(x ^ y)
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

    # Loads from a misaligned address rotate the aligned word/halfword
    def ldr(addr)
      ror(@bus.read32(addr), (addr & 3) * 8)
    end

    def ldrh(addr)
      ror(@bus.read16(addr), (addr & 1) * 8)
    end

    def ldrsb(addr)
      v = @bus.read(addr)
      v[7] == 1 ? v | 0xFFFF_FF00 : v
    end

    # An odd address loads only the byte, sign-extended
    def ldrsh(addr)
      return ldrsb(addr) if addr[0] == 1

      v = @bus.read16(addr)
      v[15] == 1 ? v | 0xFFFF_0000 : v
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

    def executable?(nibble)
      case nibble
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
      rd_index = opcode[12..15]
      offset_addr = (opcode[23] == 1 ? reg(rn_index) + offset : reg(rn_index) - offset) & 0xFFFF_FFFF
      yield(opcode[24] == 1 ? offset_addr : reg(rn_index))
      @regs[rn_index] = offset_addr if (opcode[24] == 0 || opcode[21] == 1) && (opcode[20] == 0 || rn_index != rd_index)
    end

    def determine_instruction(opcode)
      INSTRUCTION_TABLE[opcode[20..27] << 4 | opcode[4..7]]
    end
  end
end
