# frozen_string_literal: true

module RubyboyAdvance
  class Interrupt
    INTERRUPTS = {
      vblank: 0,
      hblank: 1,
      vcount: 2,
      timer0: 3,
      timer1: 4,
      timer2: 5,
      timer3: 6
    }.freeze

    # @rbs @ie: Integer
    # @rbs @if: Integer
    # @rbs @ime: Integer

    # Asked with every instruction, so they are kept ready and only worked out when a register changes
    attr_reader :irq, :halted

    alias irq? irq
    alias cpu_halted? halted

    def initialize
      @ie = 0
      @if = 0
      @ime = 0
      @halted = false
      @irq = false
    end

    def request(interrupt)
      @if |= (1 << INTERRUPTS[interrupt])
      update
    end

    def read(addr)
      case addr
      when 0x200 then @ie & 0xFF
      when 0x201 then (@ie >> 8) & 0xFF
      when 0x202 then @if & 0xFF
      when 0x203 then (@if >> 8) & 0xFF
      when 0x208 then @ime
      else 0
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
      when 0x301 then @halted = (value[7] == 0)
      end
      update
    end

    private

    # An enabled request wakes a halted CPU even with IME off
    def update
      pending = (@if & @ie) != 0
      @halted = false if pending
      @irq = pending && @ime[0] == 1
    end
  end
end
