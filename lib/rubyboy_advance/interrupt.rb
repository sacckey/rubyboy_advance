# frozen_string_literal: true

module RubyboyAdvance
  class Interrupt
    INTERRUPTS = {
      vblank: 0
    }.freeze

    def initialize
      @ie = 0
      @if = 0
      @ime = 0
      @halt_flag = false
    end

    def request(interrupt)
      @if |= (1 << INTERRUPTS[interrupt])
    end

    def read(addr)
      case addr
      when 0x200 then @ie & 0xFF
      when 0x201 then (@ie >> 8) & 0xFF
      when 0x202 then @if & 0xFF
      when 0x203 then (@if >> 8) & 0xFF
      when 0x208 then @ime
      when 0x209 then 0
      end
    end

    def write(addr, value)
      case addr
      when 0x200 then @ie = (@ie & 0xFF00) | (value & 0xFF)
      when 0x201 then @ie = (@ie & 0xFF) | (value << 8)
      when 0x202 then @if &= ~value
      when 0x203 then @if &= ~(value << 8)
      when 0x208 then @ime = value[0]
      when 0x209 then nil
      when 0x301 then @halt_flag = (value[7] == 0)
      end
    end

    def irq?
      @ime[0] == 1 && (@if & @ie) != 0
    end

    def cpu_halted?
      @halt_flag = false if (@if & @ie) != 0
      @halt_flag
    end
  end
end
