# frozen_string_literal: true

module RubyboyAdvance
  # ponytail: Direct Sound only, at a fixed 32768 Hz; no PSG, SOUNDCNT_L or SOUNDBIAS yet
  class Apu
    CYCLES_PER_SAMPLE = 512
    FIFO_WORDS = 7 # NanoBoyAdvance fifo.hh
    REFILLS = %i[fifo_a fifo_b].freeze

    def initialize
      @cnt_h = 0
      @enabled = false
      @fifos = [[], []]
      @writing = [0, 0]
      @playing = [0, 0]
      @bytes_left = [0, 0]
      @latches = [0, 0]
      @cycles = 0
      @samples = []
    end

    # Left and right by turns, as signed 16-bit values
    def take_samples
      samples = @samples
      @samples = []
      samples
    end

    def step(cycles)
      @cycles += cycles
      while @cycles >= CYCLES_PER_SAMPLE
        @cycles -= CYCLES_PER_SAMPLE
        @samples << output(1) << output(0)
      end
    end

    # A FIFO plays its next byte when its timer overflows, and asks its DMA for more once it has run low
    def timer_overflow(timer_id)
      return unless @enabled

      2.times do |i|
        next unless @cnt_h[10 + (i * 4)] == timer_id

        fifo = @fifos[i]
        low = fifo.size <= 3
        if @bytes_left[i] == 0 && !fifo.empty?
          @playing[i] = fifo.shift
          @bytes_left[i] = 4
        end
        byte = @playing[i] & 0xFF
        @latches[i] = byte[7] == 1 ? byte - 0x100 : byte
        @playing[i] >>= 8
        @bytes_left[i] -= 1 if @bytes_left[i] > 0
        yield REFILLS[i] if low
      end
    end

    def read(offset)
      case offset
      when 0x082 then @cnt_h & 0xFF
      when 0x083 then @cnt_h >> 8
      when 0x084 then @enabled ? 0x80 : 0
      end
    end

    def write(offset, value)
      case offset
      when 0x082 then @cnt_h = (@cnt_h & 0xFF00) | (value & 0x0F)
      when 0x083
        @cnt_h = (@cnt_h & 0xFF) | ((value & 0x77) << 8)
        @fifos[0].clear if value[3] == 1
        @fifos[1].clear if value[7] == 1
      when 0x084
        @enabled = value[7] == 1
        @fifos.each(&:clear) unless @enabled
      when 0x0A0..0x0A7 then write_fifo(offset, value) if @enabled
      end
    end

    private

    # ponytail: a word goes in when its top byte is written; hardware takes one for a write of any size
    def write_fifo(offset, value)
      i = offset[2]
      shift = (offset & 3) * 8
      @writing[i] = (@writing[i] & ~(0xFF << shift)) | (value << shift)
      return unless offset & 3 == 3

      # Writing to a full FIFO empties it (NanoBoyAdvance fifo.hh)
      @fifos[i].size < FIFO_WORDS ? @fifos[i] << @writing[i] : @fifos[i].clear
    end

    # side is its enable bit in SOUNDCNT_H: 0 for right, 1 for left
    def output(side)
      return 0 unless @enabled

      level = 0
      2.times do |i|
        level += @latches[i] << (1 + @cnt_h[2 + i]) if @cnt_h[8 + side + (i * 4)] == 1
      end
      level.clamp(-0x200, 0x1FF) << 6
    end
  end
end
