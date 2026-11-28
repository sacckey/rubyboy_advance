# frozen_string_literal: true

module RubyboyAdvance
  class Timer
    FAR = 1 << 40 # cycles: further than any overflow

    def initialize(interrupt)
      @interrupt = interrupt
      @cycles = 0 # One clock that never stops; every prescaler ticks on its multiples, as on hardware
      @counts = [0, 0, 0, 0] # as they were when the clock stood at @synced
      @reloads = [0, 0, 0, 0]
      @settings = [0, 0, 0, 0] # 8bit
      @synced = 0
      @next_overflow = FAR # the clock value at which a timer next overflows; nothing has to be done before it
    end

    def step(cycles)
      @cycles += cycles
      return if @cycles < @next_overflow

      sync(@cycles)
      overflows = [0, 0, 0, 0]
      4.times do |i|
        next if @settings[i][7] == 0

        @counts[i] += overflows[i - 1] unless counts_clock?(i)
        while @counts[i] >= 0x10000
          @counts[i] -= 0x10000 - @reloads[i]
          overflows[i] += 1
        end
        @interrupt.request(:"timer#{i}") if overflows[i] > 0 && @settings[i][6] == 1
      end
      @next_overflow = @synced + cycles_to_next_overflow
      # Timers 0 and 1 clock the sound FIFOs. Told last, since the sound DMA this starts can read the timers
      2.times { |i| overflows[i].times { yield i } }
    end

    # For a halted CPU to sleep through
    def cycles_to_overflow
      @next_overflow - @cycles
    end

    # ahead: how far the CPU has run on since the last step
    def read(addr, ahead)
      tm_index = (addr - 0x100) / 4
      shift_amount = (addr - 0x100) % 4

      case shift_amount
      when 0, 1 then (count(tm_index, @cycles + ahead) >> (shift_amount * 8)) & 0xFF
      when 2 then @settings[tm_index]
      else 0
      end
    end

    def write(addr, value, ahead)
      tm_index = (addr - 0x100) / 4
      shift_amount = (addr - 0x100) % 4

      case shift_amount
      when 0, 1
        @reloads[tm_index] = (@reloads[tm_index] & ~(0xFF << (shift_amount * 8))) | (value << (shift_amount * 8))
      when 2
        sync(@cycles + ahead)
        before = @settings[tm_index][7]
        @settings[tm_index] = value
        @counts[tm_index] = @reloads[tm_index] if before == 0 && @settings[tm_index][7] == 1
        @next_overflow = @synced + cycles_to_next_overflow
      end
    end

    private

    def counts_clock?(index)
      @settings[index][7] == 1 && (index == 0 || @settings[index][2] == 0)
    end

    # Brings @counts up to now, leaving overflows to step
    def sync(now)
      4.times { |i| @counts[i] = count(i, now) }
      @synced = now
    end

    # The counter at now: one that counts the clock has moved on since @synced, without an overflow
    def count(index, now)
      return @counts[index] unless counts_clock?(index)

      prescaler_i = prescaler(index)
      @counts[index] + (now / prescaler_i) - (@synced / prescaler_i)
    end

    # From @synced. A timer that counts overflows waits for those
    def cycles_to_next_overflow
      nearest = FAR
      4.times do |i|
        next unless counts_clock?(i)

        prescaler_i = prescaler(i)
        cycles = (((@synced / prescaler_i) + 0x10000 - @counts[i]) * prescaler_i) - @synced
        nearest = cycles if cycles < nearest
      end
      nearest
    end

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
