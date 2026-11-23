# frozen_string_literal: true

module RubyboyAdvance
  # ponytail: samples at a fixed 32768 Hz, not the rate SOUNDBIAS asks for, and the PSG channels catch up once a sample
  class Apu
    CYCLES_PER_SAMPLE = 512
    FIFO_WORDS = 7 # NanoBoyAdvance fifo.hh
    REFILLS = %i[fifo_a fifo_b].freeze
    PSG_VOLUMES = [1, 2, 4, 0].freeze # SOUNDCNT_H bits 0-1
    # The PSG channel that each I/O offset from 0x60 to 0x7F belongs to, or -1
    PSG_CHANNELS = [
      0, -1, 0, 0, 0, 0, -1, -1,
      1, 1, -1, -1, 1, 1, -1, -1,
      2, -1, 2, 2, 2, 2, -1, -1,
      3, 3, -1, -1, 3, 3, -1, -1
    ].freeze

    def initialize
      @cnt_l = 0
      @cnt_h = 0
      @bias = 0x200 # as the BIOS leaves it
      @enabled = false
      @fifos = [[], []]
      @writing = [0, 0]
      @playing = [0, 0]
      @bytes_left = [0, 0]
      @latches = [0, 0]
      @wave_ram = Array.new(2) { Array.new(16, 0) }
      reset_psg
      @sequencer = 0
      @cycles = 0
      @samples = []
    end

    # Left and right by turns, as signed 16-bit values
    def take_samples
      samples = @samples
      @samples = []
      samples
    end

    def cycles_to_sample
      CYCLES_PER_SAMPLE - @cycles
    end

    def step(cycles)
      @cycles += cycles
      while @cycles >= CYCLES_PER_SAMPLE
        @cycles -= CYCLES_PER_SAMPLE
        @square1.step(CYCLES_PER_SAMPLE)
        @square2.step(CYCLES_PER_SAMPLE)
        @wave.step(CYCLES_PER_SAMPLE)
        @noise.step(CYCLES_PER_SAMPLE)
        @sequencer = (@sequencer + 1) & 63 # 512 Hz is every 64 samples
        if @sequencer == 0
          @square1.tick
          @square2.tick
          @wave.tick
          @noise.tick
        end
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
      when 0x060..0x07F
        read_psg(PSG_CHANNELS[offset - 0x60], offset & 7)
      when 0x080 then @cnt_l & 0xFF
      when 0x081 then @cnt_l >> 8
      when 0x082 then @cnt_h & 0xFF
      when 0x083 then @cnt_h >> 8
      when 0x084 then (@enabled ? 0x80 : 0) | psg_status
      when 0x088 then @bias & 0xFF
      when 0x089 then @bias >> 8
      when 0x090..0x09F then @wave.read_ram(offset & 0xF)
      else 0
      end
    end

    def write(offset, value)
      case offset
      when 0x060..0x07F
        write_psg(PSG_CHANNELS[offset - 0x60], offset & 7, value) if @enabled
      when 0x080 then @cnt_l = (@cnt_l & 0xFF00) | (value & 0x77) if @enabled
      when 0x081 then @cnt_l = (@cnt_l & 0xFF) | (value << 8) if @enabled
      when 0x082 then @cnt_h = (@cnt_h & 0xFF00) | (value & 0x0F)
      when 0x083
        @cnt_h = (@cnt_h & 0xFF) | ((value & 0x77) << 8)
        @fifos[0].clear if value[3] == 1
        @fifos[1].clear if value[7] == 1
      when 0x084
        @enabled = value[7] == 1
        return if @enabled

        @fifos.each(&:clear)
        @cnt_l = 0
        reset_psg
      when 0x088 then @bias = (@bias & 0xFF00) | (value & 0xFE)
      when 0x089 then @bias = (@bias & 0xFF) | ((value & 0xC3) << 8)
      when 0x090..0x09F then @wave.write_ram(offset & 0xF, value)
      when 0x0A0..0x0A7 then write_fifo(offset, value) if @enabled
      end
    end

    private

    def reset_psg
      @square1 = Psg::Square.new
      @square2 = Psg::Square.new
      @wave = Psg::Wave.new(@wave_ram)
      @noise = Psg::Noise.new
    end

    # A channel numbers its registers as the bytes of SOUND1CNT_L, _H and _X; channels 2 and 4 have no _L,
    # so their first two bytes are those of _H
    def read_psg(channel, reg)
      case channel
      when 0 then @square1.read(reg)
      when 1 then @square2.read(reg < 2 ? reg + 2 : reg)
      when 2 then @wave.read(reg)
      when 3 then @noise.read(reg < 2 ? reg + 2 : reg)
      else 0
      end
    end

    def write_psg(channel, reg, value)
      case channel
      when 0 then @square1.write(reg, value)
      when 1 then @square2.write(reg < 2 ? reg + 2 : reg, value)
      when 2 then @wave.write(reg, value)
      when 3 then @noise.write(reg < 2 ? reg + 2 : reg, value)
      end
    end

    # SOUNDCNT_X bits 0-3
    def psg_status
      (@square1.enabled? ? 1 : 0) | (@square2.enabled? ? 2 : 0) | (@wave.enabled? ? 4 : 0) | (@noise.enabled? ? 8 : 0)
    end

    # ponytail: a word goes in when its top byte is written; hardware takes one for a write of any size
    def write_fifo(offset, value)
      i = offset[2]
      shift = (offset & 3) * 8
      @writing[i] = (@writing[i] & ~(0xFF << shift)) | (value << shift)
      return unless offset & 3 == 3

      # Writing to a full FIFO empties it (NanoBoyAdvance fifo.hh)
      @fifos[i].size < FIFO_WORDS ? @fifos[i] << @writing[i] : @fifos[i].clear
    end

    # side is 0 for right and 1 for left, as the enable bits go in SOUNDCNT_L and SOUNDCNT_H
    def output(side)
      return 0 unless @enabled

      psg = 0
      enables = @cnt_l >> (8 + (side * 4))
      psg += @square1.sample if enables[0] == 1
      psg += @square2.sample if enables[1] == 1
      psg += @wave.sample if enables[2] == 1
      psg += @noise.sample if enables[3] == 1
      level = (psg * PSG_VOLUMES[@cnt_h & 3] * (((@cnt_l >> (side * 4)) & 7) + 1)) >> 5
      2.times do |i|
        level += @latches[i] << (1 + @cnt_h[2 + i]) if @cnt_h[8 + side + (i * 4)] == 1
      end
      ((level + (@bias & 0x3FF)).clamp(0, 0x3FF) - 0x200) << 6
    end
  end
end
