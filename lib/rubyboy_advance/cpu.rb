# frozen_string_literal: true

module RubyboyAdvance
  class Cpu
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
      return unless executable?(opcode)

      raise format('Unknown opcode %<opcode>08X at %<address>08X', opcode:, address:)
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

    def flag_n
      @cpsr[31] == 1
    end

    def flag_c
      @cpsr[29] == 1
    end

    def flag_v
      @cpsr[28] == 1
    end

    def executable?(opcode)
      case opcode >> 28
      when 0x0 then return flag_z
      when 0x1 then return !flag_z
      when 0x2 then return flag_c
      when 0x3 then return !flag_c
      when 0x4 then return flag_n
      when 0x5 then return !flag_n
      when 0x6 then return flag_v
      when 0x7 then return !flag_v
      when 0x8 then return flag_c && !flag_z
      when 0x9 then return !flag_c || flag_z
      when 0xA then return flag_n == flag_v
      when 0xB then return flag_n != flag_v
      when 0xC then return !flag_z && (flag_n == flag_v)
      when 0xD then return flag_z || (flag_n != flag_v)
      when 0xE then return true
      when 0xF then return false
      end

      false
    end
  end
end
