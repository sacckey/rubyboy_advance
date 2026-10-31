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
      when 0x208 then @ime & 0xFF
      when 0x209 then (@ime >> 8) & 0xFF
      end
    end

    def write(addr, value)
      case addr
      when 0x200 then @ie = (@ie & 0xFF00) | (value & 0xFF)
      when 0x201 then @ie = (@ie & 0xFF) | (value << 8)
      when 0x202 then @if &= ~value
      when 0x203 then @if &= ~(value << 8)
      when 0x208 then @ime = (@ime & 0xFF00) | (value & 0xFF)
      when 0x209 then @ime = (@ime & 0xFF) | (value << 8)
      end
    end

    def irq?
      @ime[0] == 1 && (@if & @ie) != 0
    end
  end
end
