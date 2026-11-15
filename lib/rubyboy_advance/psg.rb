# frozen_string_literal: true

module RubyboyAdvance
  # The Game Boy's four channels, after NanoBoyAdvance (hw/apu/channel).
  # Each numbers its registers as the bytes of SOUND1CNT_L, _H and _X: 0 sweep, 2 length, 3 envelope, 4 frequency, 5 control
  module Psg
    class Channel
      attr_reader :sample

      def initialize(max_length)
        @max_length = max_length
        @enabled = false
        @dac = false
        @sequence = 0
        @length = 0
        @length_enabled = false
        @volume = 0
        @initial_volume = 0
        @envelope_up = false
        @envelope_divider = 0
        @envelope_step = 0
        @envelope_active = false
        @timer = 0
        @sample = 0
      end

      def enabled? = @enabled && @dac

      def step(cycles)
        return @sample = 0 unless enabled?

        @timer -= cycles
        while @timer <= 0
          @timer += period
          generate
        end
      end

      # One step of the 512 Hz frame sequencer: the length on every other step, the envelope on the last of eight
      def tick
        if @sequence.even? && @length_enabled && @length > 0
          @length -= 1
          @enabled = false if @length == 0
        end
        step_envelope if @sequence == 7
        @sequence = (@sequence + 1) & 7
      end

      def read(reg) = reg == 5 && @length_enabled ? 0x40 : 0

      def write(reg, value)
        case reg
        when 2 then @length = @max_length - (value & (@max_length - 1))
        when 5
          @length_enabled = value[6] == 1
          restart if value[7] == 1 && @dac
        end
      end

      private

      def restart
        @timer = period unless @enabled
        @enabled = true
        @sequence = 0
        @length = @max_length if @length == 0
        @volume = @initial_volume
        @envelope_step = @envelope_divider
        @envelope_active = true
      end

      def read_envelope = @envelope_divider | (@envelope_up ? 8 : 0) | (@initial_volume << 4)

      def write_envelope(value)
        @envelope_divider = value & 7
        @envelope_up = value[3] == 1
        @initial_volume = value >> 4
        @dac = value >> 3 != 0
        @enabled &&= @dac
      end

      def step_envelope
        return @envelope_step = (@envelope_step - 1) & 7 unless @envelope_step == 1

        @envelope_step = @envelope_divider
        return unless @envelope_active && @envelope_divider != 0

        if @volume == (@envelope_up ? 15 : 0)
          @envelope_active = false
        else
          @volume += @envelope_up ? 1 : -1
        end
      end
    end

    # Channels 1 and 2. Channel 2 has no register 0, so it never sweeps
    class Square < Channel
      HIGH_STEPS = [1, 2, 4, 6].freeze # out of 8, by duty

      def initialize
        super(64)
        @duty = 0
        @phase = 0
        @freq = 0
        @shadow_freq = 0
        @sweep_shift = 0
        @sweep_down = false
        @sweep_divider = 0
        @sweep_step = 0
      end

      def tick
        @enabled = false if @sequence & 3 == 2 && sweep_past_top?
        super
      end

      def read(reg)
        case reg
        when 0 then @sweep_shift | (@sweep_down ? 8 : 0) | (@sweep_divider << 4)
        when 2 then @duty << 6
        when 3 then read_envelope
        else super
        end
      end

      def write(reg, value)
        case reg
        when 0
          @sweep_shift = value & 7
          @sweep_down = value[3] == 1
          @sweep_divider = (value >> 4) & 7
        when 2 then @duty = value >> 6
        when 3 then write_envelope(value)
        when 4 then @freq = (@freq & 0x700) | value
        when 5 then @freq = (@freq & 0xFF) | ((value & 7) << 8)
        end
        super
      end

      private

      def period = 16 * (2048 - @freq)

      def generate
        @sample = (@phase < HIGH_STEPS[@duty] ? 8 : -8) * @volume
        @phase = (@phase + 1) & 7
      end

      def restart
        super
        @phase = 0
        @shadow_freq = @freq
        @sweep_step = @sweep_divider
      end

      # Moves the frequency by a fraction of itself; a result past 2047 stops the channel. A period of 0 never comes due
      def sweep_past_top?
        return false unless (@sweep_step -= 1) == 0

        @sweep_step = @sweep_divider
        freq = @shadow_freq + ((@shadow_freq >> @sweep_shift) * (@sweep_down ? -1 : 1))
        return true if freq > 2047

        @freq = @shadow_freq = freq if @sweep_shift != 0
        false
      end
    end

    # Channel 3. Its DAC bit is the playback bit of register 0, which mutes it without stopping it
    class Wave < Channel
      VOLUMES = [0, 4, 2, 1].freeze

      # ram is two banks of 16 bytes, and outlives the channel when the master enable resets it
      def initialize(ram)
        super(256)
        @ram = ram
        @two_banks = 0
        @bank = 0
        @level = 0
        @forced = false
        @freq = 0
        @phase = 0
      end

      def read(reg)
        case reg
        when 0 then (@two_banks << 5) | (@bank << 6) | (@dac ? 0x80 : 0)
        when 3 then (@level << 5) | (@forced ? 0x80 : 0)
        else super
        end
      end

      def write(reg, value)
        case reg
        when 0
          @two_banks = value[5]
          @bank = value[6]
          @dac = value[7] == 1
        when 3
          @level = (value >> 5) & 3
          @forced = value[7] == 1
        when 4 then @freq = (@freq & 0x700) | value
        when 5 then @freq = (@freq & 0xFF) | ((value & 7) << 8)
        end
        super
      end

      # The bank that is not playing is the one the wave RAM registers reach
      def read_ram(index) = @ram[@bank ^ 1][index]

      def write_ram(index, value)
        @ram[@bank ^ 1][index] = value
      end

      private

      def period = 8 * (2048 - @freq)

      def generate
        byte = @ram[@bank][@phase >> 1]
        nibble = @phase.even? ? byte >> 4 : byte & 15
        @sample = (nibble - 8) * 4 * (@forced ? 3 : VOLUMES[@level])
        @phase = (@phase + 1) & 31
        @bank ^= @two_banks if @phase == 0
      end

      def restart
        super
        @phase = 0
        @bank = 0 if @two_banks == 1
      end
    end

    # Channel 4
    class Noise < Channel
      def initialize
        super(64)
        @ratio = 0
        @short = 0
        @shift = 0
        @lfsr = 0
      end

      def read(reg)
        case reg
        when 3 then read_envelope
        when 4 then @ratio | (@short << 3) | (@shift << 4)
        else super
        end
      end

      def write(reg, value)
        case reg
        when 3 then write_envelope(value)
        when 4
          @ratio = value & 7
          @short = value[3]
          @shift = value >> 4
        end
        super
      end

      private

      def period = @ratio == 0 ? 32 << @shift : (64 << @shift) * @ratio

      # ponytail: one loop pass for each shift, up to 16 a sample at the highest rate
      def generate
        carry = @lfsr & 1
        @lfsr >>= 1
        @lfsr ^= @short == 1 ? 0x60 : 0x6000 if carry == 1
        @sample = (carry == 1 ? 8 : -8) * @volume
      end

      def restart
        super
        @lfsr = @short == 1 ? 0x40 : 0x4000
      end
    end
  end
end
