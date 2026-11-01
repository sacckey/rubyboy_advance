# frozen_string_literal: true

module RubyboyAdvance
  class Timer
    def initialize(interrupt)
      @interrupt = interrupt
      @cycles = 0 # One clock that never stops; every prescaler ticks on its multiples, as on hardware
      @counts = [0, 0, 0, 0]
      @reloads = [0, 0, 0, 0]
      @settings = [0, 0, 0, 0] # 8bit
    end

    def step(cycles)
      before = @cycles
      @cycles += cycles
      overflows = 0
      4.times do |i|
        if @settings[i][7] == 0
          overflows = 0
          next
        end

        if i > 0 && @settings[i][2] == 1
          @counts[i] += overflows
        else
          prescaler_i = prescaler(i)
          @counts[i] += (@cycles / prescaler_i) - (before / prescaler_i)
        end

        overflows = 0
        while @counts[i] >= 0x10000
          @counts[i] -= 0x10000 - @reloads[i]
          overflows += 1
        end
        @interrupt.request(:"timer#{i}") if overflows > 0 && @settings[i][6] == 1
      end
    end

    def read(addr)
      tm_index = (addr - 0x100) / 4
      shift_amount = (addr - 0x100) % 4

      case shift_amount
      when 0, 1 then (@counts[tm_index] >> (shift_amount * 8)) & 0xFF
      when 2 then @settings[tm_index]
      else 0
      end
    end

    def write(addr, value)
      tm_index = (addr - 0x100) / 4
      shift_amount = (addr - 0x100) % 4

      case shift_amount
      when 0, 1
        @reloads[tm_index] = (@reloads[tm_index] & ~(0xFF << (shift_amount * 8))) | (value << (shift_amount * 8))
      when 2
        before = @settings[tm_index][7]
        @settings[tm_index] = value
        @counts[tm_index] = @reloads[tm_index] if before == 0 && @settings[tm_index][7] == 1
      end
    end

    private

    def prescaler(index)
      case @settings[index] & 0b11
      when 0 then 1
      when 1 then 64
      when 2 then 256
      when 3 then 1024
      end
    end
  end
end
