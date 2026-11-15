# frozen_string_literal: true

RSpec.describe RubyboyAdvance::Psg do
  let(:interrupt) { RubyboyAdvance::Interrupt.new }
  let(:apu) { RubyboyAdvance::Apu.new }
  let(:bus) do
    RubyboyAdvance::Bus.new(
      [], [], RubyboyAdvance::Ppu.new(interrupt), RubyboyAdvance::Sram.new, interrupt,
      RubyboyAdvance::Timer.new(interrupt), RubyboyAdvance::Keypad.new(interrupt), apu
    )
  end

  # The left level of each of the next samples: with the volumes of the before block, the sum of the channels
  def play(samples)
    apu.step(512 * samples)
    apu.take_samples.each_slice(2).map { |left, _| left / 64 }
  end

  def level = play(1)[0]
  def playing?(channel) = bus.read16(0x0400_0084)[channel] == 1

  # A frequency whose waveform takes a step once every so many samples
  def square_freq(samples) = 2048 - (samples * 32)
  def wave_freq(samples) = 2048 - (samples * 64)

  # Square channels 1 and 2 have the same registers in different places: duty and envelope, then frequency and control
  def square_regs(channel) = [[0x0400_0062, 0x0400_0064], [0x0400_0068, 0x0400_006C]][channel]

  def start_square(channel, duty_envelope, control)
    bus.write16(square_regs(channel)[0], duty_envelope)
    bus.write16(square_regs(channel)[1], control)
  end

  def start_wave(control, volume: 0x2000, select: 0x80)
    bus.write16(0x0400_0070, select)
    bus.write16(0x0400_0072, volume)
    bus.write16(0x0400_0074, control)
  end

  def start_noise(envelope, control)
    bus.write16(0x0400_0078, envelope)
    bus.write16(0x0400_007C, control)
  end

  before do
    bus.write16(0x0400_0084, 0x80) # master enable
    bus.write16(0x0400_0080, 0xFF77) # every channel on both sides at full volume
    bus.write16(0x0400_0082, 0x0002) # PSG at 100%
  end

  describe 'registers' do
    {
      'SOUND1CNT_L' => [0x60, 0x007F], 'SOUND1CNT_H' => [0x62, 0xFFC0], 'SOUND1CNT_X' => [0x64, 0x4000],
      'SOUND2CNT_L' => [0x68, 0xFFC0], 'SOUND2CNT_H' => [0x6C, 0x4000],
      'SOUND3CNT_L' => [0x70, 0x00E0], 'SOUND3CNT_H' => [0x72, 0xE000], 'SOUND3CNT_X' => [0x74, 0x4000],
      'SOUND4CNT_L' => [0x78, 0xFF00], 'SOUND4CNT_H' => [0x7C, 0x40FF],
      'SOUNDCNT_L' => [0x80, 0xFF77]
    }.each do |name, (offset, readable)|
      it "reads back #{format('%#06x', readable)} of #{name}" do
        bus.write16(0x0400_0000 + offset, 0xFFFF)

        expect(bus.read16(0x0400_0000 + offset)).to eq(readable)
      end

      it "ignores a write to #{name} while the master enable is off" do
        bus.write16(0x0400_0084, 0)
        bus.write16(0x0400_0000 + offset, 0xFFFF)
        bus.write16(0x0400_0084, 0x80)

        expect(bus.read16(0x0400_0000 + offset)).to eq(0)
      end

      it "clears #{name} when the master enable goes off" do
        bus.write16(0x0400_0000 + offset, 0xFFFF)
        bus.write16(0x0400_0084, 0)

        expect(bus.read16(0x0400_0000 + offset)).to eq(0)
      end
    end

    it 'reads the unused halves as 0' do
      [0x66, 0x6A, 0x6E, 0x76, 0x7A, 0x7E].each { bus.write16(0x0400_0000 + it, 0xFFFF) }

      expect([0x66, 0x6A, 0x6E, 0x76, 0x7A, 0x7E].map { bus.read16(0x0400_0000 + it) }).to eq([0] * 6)
    end

    it 'shows in SOUNDCNT_X which channels are playing' do
      expect(bus.read16(0x0400_0084)).to eq(0x80)

      start_square(1, 0xF000, 0x8000)
      start_noise(0xF000, 0x8000)

      expect(bus.read16(0x0400_0084)).to eq(0x8A)
    end
  end

  2.times do |channel|
    describe "square channel #{channel + 1}" do
      it 'starts a step of its period after the trigger and steps through the wave' do
        start_square(channel, 0xF080, 0x8000 | square_freq(2)) # duty 50%, volume 15

        expect(play(17)).to eq([0] + ([120] * 8) + ([-120] * 8))
      end

      { 0 => 1, 1 => 2, 2 => 4, 3 => 6 }.each do |duty, high|
        it "is high for #{high} steps of 8 with duty #{duty}" do
          start_square(channel, 0xF000 | (duty << 6), 0x8000 | square_freq(1))

          expect(play(8)).to eq(([120] * high) + ([-120] * (8 - high)))
        end
      end

      it 'takes its pitch from all 11 bits of the frequency' do
        start_square(channel, 0xF000, 0x8000 | 0x7FF) # 16 cycles a step: every 512 cycles it is back where it was

        expect(play(4)).to eq([-120] * 4)
      end

      it 'plays at the volume of the envelope register' do
        start_square(channel, 0x5080, 0x8000 | square_freq(1))

        expect(play(8)).to eq(([40] * 4) + ([-40] * 4))
      end

      it 'starts from the beginning of the wave when triggered again, once the step under way ends' do
        start_square(channel, 0xF000, 0x8000 | square_freq(2)) # duty 12.5%: high for the first step only
        play(5) # half-way through the second step

        bus.write16(square_regs(channel)[1], 0x8000 | square_freq(2))

        expect(play(4)).to eq([120, 120, -120, -120])
      end

      it 'does not start without the trigger bit' do
        start_square(channel, 0xF080, square_freq(1))

        expect([playing?(channel), play(4)]).to eq([false, [0] * 4])
      end

      it 'does not start with the top five envelope bits clear, even when they are set afterwards' do
        start_square(channel, 0x0780, 0x8000 | square_freq(1))

        bus.write16(square_regs(channel)[0], 0xF080)

        expect([playing?(channel), play(4)]).to eq([false, [0] * 4])
      end

      it 'stops when the top five envelope bits are cleared, and stays off when they are set again' do
        start_square(channel, 0xF080, 0x8000 | square_freq(1))

        bus.write16(square_regs(channel)[0], 0x0780)
        expect([playing?(channel), play(4)]).to eq([false, [0] * 4])

        bus.write16(square_regs(channel)[0], 0xF080)
        expect([playing?(channel), play(4)]).to eq([false, [0] * 4])
      end

      it 'keeps the high bits of the frequency when only the low byte is written' do
        start_square(channel, 0xF080, 0x8000 | 0x7C0)

        bus.write(square_regs(channel)[1], 0x80) # 0x780: 4 samples a step, so high for 16

        expect(play(64).chunk_while { |a, b| a == b }.map(&:size).max).to eq(16)
      end

      describe 'envelope' do
        # The volume after so many 64 Hz steps, each 512 samples long
        def volume_after(steps)
          play(512 * steps)
          play(8).max / 8
        end

        it 'goes down a step every 1/64 s with a period of 1' do
          start_square(channel, 0xF180, 0x8000 | square_freq(1))

          expect([volume_after(0), volume_after(1), volume_after(1)]).to eq([15, 14, 13])
        end

        it 'changes just as the eighth sequencer step ends' do
          start_square(channel, 0xF180, 0x8000 | square_freq(1))
          play(504)

          expect(play(16).map(&:abs)).to eq(([120] * 8) + ([112] * 8))
        end

        it 'goes up with bit 3' do
          start_square(channel, 0x0980, 0x8000 | square_freq(1))

          expect([volume_after(0), volume_after(1), volume_after(1)]).to eq([0, 1, 2])
        end

        it 'takes a step every period' do
          start_square(channel, 0xF380, 0x8000 | square_freq(1))

          expect([volume_after(2), volume_after(1), volume_after(3)]).to eq([15, 14, 13])
        end

        it 'stays put with a period of 0' do
          start_square(channel, 0xF080, 0x8000 | square_freq(1))

          expect(volume_after(8)).to eq(15)
        end

        it 'stops at 15 going up and at 0 going down' do
          start_square(channel, 0xE980, 0x8000 | square_freq(1))
          expect(volume_after(3)).to eq(15)

          start_square(channel, 0x1180, 0x8000 | square_freq(1))
          expect(volume_after(3)).to eq(0)
        end

        it 'does not move again once it has stopped, even turned around' do
          start_square(channel, 0xE980, 0x8000 | square_freq(1))
          volume_after(3)

          bus.write16(square_regs(channel)[0], 0xE180) # down

          expect(volume_after(2)).to eq(15)
        end

        it 'picks up a period written while it plays, within eight steps' do
          start_square(channel, 0xF080, 0x8000 | square_freq(1))

          bus.write16(square_regs(channel)[0], 0xF180)

          expect([volume_after(7), volume_after(1)]).to eq([15, 14])
        end

        it 'starts over from the register when triggered again' do
          start_square(channel, 0xF180, 0x8000 | square_freq(1))
          volume_after(3)

          bus.write16(square_regs(channel)[1], 0x8000 | square_freq(1))

          expect(volume_after(0)).to eq(15)
        end
      end

      describe 'length' do
        it 'stops the channel after 64 minus the length steps of 1/256 s with bit 14' do
          start_square(channel, 0xF080 | 62, 0xC000 | square_freq(1)) # 2 steps: at samples 64 and 192
          play(191)
          expect(playing?(channel)).to be(true)

          expect([play(4), playing?(channel)]).to eq([[-120, 0, 0, 0], false])
        end

        it 'does not stop it without bit 14' do
          start_square(channel, 0xF080 | 63, 0x8000 | square_freq(1))
          play(64)

          expect(playing?(channel)).to be(true)
        end

        it 'runs for all 64 steps after a length of 0' do
          start_square(channel, 0xF080, 0xC000 | square_freq(1))
          play(64 + (63 * 128) - 1)
          expect(playing?(channel)).to be(true)

          play(1)

          expect(playing?(channel)).to be(false)
        end

        it 'starts from 64 again when triggered after it ran out' do
          start_square(channel, 0xF080 | 63, 0xC000 | square_freq(1))
          play(1024)

          bus.write16(square_regs(channel)[1], 0xC000 | square_freq(1))
          play(64 + (63 * 128) - 1)
          expect(playing?(channel)).to be(true)

          play(1)

          expect(playing?(channel)).to be(false)
        end

        it 'counts from the trigger: the sequencer of the channel starts over' do
          start_square(channel, 0xF080 | 63, 0xC000 | square_freq(1))
          play(100) # the first sequencer step was at sample 64, the second comes at 128
          start_square(channel, 0xF080 | 62, 0xC000 | square_freq(1))

          play(28 + 127)
          expect(playing?(channel)).to be(true)

          play(1)
          expect(playing?(channel)).to be(false)
        end
      end
    end
  end

  describe 'sweep of channel 1' do
    # How many samples a step of the wave now takes: 64 - frequency / 32. Takes 600 samples to tell
    def step_samples
      levels = play(600)
      first = levels.index { it < 0 }
      rise = levels[first..].index { it > 0 } + first
      levels[rise..].index { it < 0 }
    end

    def start_sweep(sweep, freq)
      bus.write16(0x0400_0060, sweep)
      start_square(0, 0xF000, 0x8000 | freq)
    end

    { 1 => 192, 2 => 448, 7 => 1728 }.each do |period, samples|
      it "works out a new frequency #{period} steps of 1/128 s after the trigger, and stops the channel if it is past 2047" do
        start_sweep(period << 4, 1024) # shift 0: 1024 + 1024
        play(samples - 1)
        expect(playing?(0)).to be(true)

        play(1)

        expect(playing?(0)).to be(false)
      end
    end

    it 'raises the frequency by itself shifted right' do
      start_sweep(0x72, 1024)
      play(1100)
      expect(step_samples).to eq(32)

      play(28) # sample 1728

      expect(step_samples).to eq(64 - (1280 / 32))
    end

    it 'lowers it with bit 3' do
      start_sweep(0x7A, 1024)
      play(1728)

      expect(step_samples).to eq(64 - (768 / 32))
    end

    it 'goes on from the frequency it reached, a period later' do
      start_sweep(0x7A, 1024)
      play(1728 + 1792)

      expect(step_samples).to eq(64 - (576 / 32))
    end

    it 'stops the channel when a later frequency would pass 2047' do
      start_sweep(0x11, 1024) # 1536, then 2304
      play(192 + 255)
      expect(playing?(0)).to be(true)

      play(1)

      expect(playing?(0)).to be(false)
    end

    it 'leaves the frequency with a shift of 0' do
      start_sweep(0x10, 992) # 1984 is within range, and not taken
      play(192)

      expect([playing?(0), step_samples]).to eq([true, 64 - 31])
    end

    it 'does nothing with a period and a shift of 0' do
      start_sweep(0x00, 1024)
      play(1024)

      expect([playing?(0), step_samples]).to eq([true, 32])
    end

    it 'does not reach channel 2, whose first register is its duty' do
      bus.write16(0x0400_0068, 0xF012) # as a sweep this would be period 1, shift 2
      bus.write16(0x0400_006C, 0x8000 | 1024)
      play(192)

      expect(step_samples).to eq(32)
    end
  end

  describe 'wave channel' do
    let(:bytes) { [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0xFE, 0xDC, 0xBA, 0x98, 0x76, 0x54, 0x32, 0x10] }
    let(:nibbles) { [*0..15, *15.downto(0)] }

    # Bank 0 holds bytes; bank 1 holds them backwards
    before do
      bus.write16(0x0400_0070, 0x40)
      bytes.each_with_index { |byte, i| bus.write(0x0400_0090 + i, byte) }
      bus.write16(0x0400_0070, 0x00)
      bytes.reverse.each_with_index { |byte, i| bus.write(0x0400_0090 + i, byte) }
    end

    it 'plays the 32 samples of its bank, the high half of each byte first' do
      start_wave(0x8000 | wave_freq(1))

      expect(play(33)).to eq(nibbles.map { (it - 8) * 16 } + [-128])
    end

    it 'plays the other bank with bit 6' do
      start_wave(0x8000 | wave_freq(1), select: 0xC0)

      expect(play(4)).to eq([0x10, 0x32].flat_map { [it >> 4, it & 15] }.map { (it - 8) * 16 })
    end

    it 'plays both banks in turn with bit 5, from bank 0' do
      start_wave(0x8000 | wave_freq(1), select: 0xE0)
      levels = play(66)

      expect([levels[0, 2], levels[32, 2], levels[64, 2]]).to eq([[-128, -112], [-112, -128], [-128, -112]])
    end

    it 'takes its pitch from all 11 bits of the frequency' do
      start_wave(0x8000 | wave_freq(2))
      expect(play(5)).to eq([0, -128, -128, -112, -112])

      start_wave(0x8000 | 0x7FF) # 8 cycles a sample: every 512 cycles it has gone round twice

      expect(play(3)).to eq([-128] * 3)
    end

    { 0 => 0, 1 => 4, 2 => 2, 3 => 1 }.each do |code, volume|
      it "plays at #{volume} quarters with volume #{code}" do
        start_wave(0x8000 | wave_freq(1), volume: code << 13)

        expect(play(2)).to eq([-8 * 4 * volume, -7 * 4 * volume])
      end
    end

    it 'plays at 3 quarters with bit 15 of SOUND3CNT_H, whatever the volume' do
      start_wave(0x8000 | wave_freq(1), volume: 0xA000)

      expect(play(2)).to eq([-96, -84])
    end

    it 'does not start with the playback bit clear, even when it is set afterwards' do
      start_wave(0x8000 | wave_freq(1), select: 0x00)
      expect([playing?(2), play(2)]).to eq([false, [0, 0]])

      bus.write16(0x0400_0070, 0x80)

      expect([playing?(2), play(2)]).to eq([false, [0, 0]])
    end

    it 'keeps the high bits of the frequency when only the low byte is written' do
      start_wave(0x8000 | 0x7C0)

      bus.write(0x0400_0074, 0x80) # 0x780: 2 samples for each of its samples

      expect(play(8)).to eq([-128, -128, -112, -112, -96, -96, -80, -80])
    end

    it 'is silent while the playback bit is clear and goes on when it is set again' do
      start_wave(0x8000 | wave_freq(1))
      play(2)
      bus.write16(0x0400_0070, 0x00)
      expect([playing?(2), play(2)]).to eq([false, [0, 0]])

      bus.write16(0x0400_0070, 0x80)

      expect([playing?(2), play(2)]).to eq([true, [-96, -80]])
    end

    it 'stops after 256 minus the length steps of 1/256 s with bit 14' do
      start_wave(0xC000 | wave_freq(1), volume: 0x2000 | 254)
      play(191)
      expect(playing?(2)).to be(true)

      play(1)

      expect(playing?(2)).to be(false)
    end

    it 'runs for all 256 steps after a length of 0' do
      start_wave(0xC000 | wave_freq(1))
      play(64 + (255 * 128) - 1)
      expect(playing?(2)).to be(true)

      play(1)

      expect(playing?(2)).to be(false)
    end

    it 'reads and writes the bank that is not selected' do
      expect(bus.read(0x0400_0090)).to eq(0x10)

      bus.write16(0x0400_0070, 0x40)

      expect(bus.read(0x0400_0090)).to eq(0x01)
    end

    it 'keeps the wave RAM while the master enable is off, and still takes writes' do
      bus.write16(0x0400_0084, 0)
      bus.write(0x0400_009F, 0xAA)

      expect([bus.read(0x0400_0090), bus.read(0x0400_009F)]).to eq([0x10, 0xAA])
    end
  end

  describe 'noise channel' do
    # A reference for the shift register: 1 where a bit falls out
    def lfsr_bits(count, start, taps)
      lfsr = start
      Array.new(count) do
        carry = lfsr & 1
        lfsr >>= 1
        lfsr ^= taps if carry == 1
        carry
      end
    end

    it 'is low until the first bit falls out of its 15-bit register' do
      start_noise(0xF000, 0x8000 | 0x40) # shift 4, ratio 0: a bit every sample

      expect(play(16)).to eq(([-120] * 14) + [120, -120])
    end

    it 'runs through 32767 states in 15-bit mode' do
      start_noise(0xF000, 0x8000 | 0x40)
      levels = play(32767 + 20)

      expect(levels[0, 32767].count(120)).to eq(16384)
      expect(levels[32767, 20]).to eq(levels[0, 20])
    end

    it 'runs through 127 states in 7-bit mode with bit 3' do
      start_noise(0xF000, 0x8000 | 0x48)
      levels = play(127 * 2)

      expect(levels[0, 8]).to eq(([-120] * 6) + [120, -120])
      expect(levels[0, 127].count(120)).to eq(64)
      expect(levels[127, 127]).to eq(levels[0, 127])
    end

    it 'follows the feedback taps of both widths' do
      start_noise(0xF000, 0x8000 | 0x40)
      expect(play(200)).to eq(lfsr_bits(200, 0x4000, 0x6000).map { it == 1 ? 120 : -120 })

      start_noise(0xF000, 0x8000 | 0x48)
      expect(play(200)).to eq(lfsr_bits(200, 0x40, 0x60).map { it == 1 ? 120 : -120 })
    end

    { [4, 0] => 1, [3, 1] => 1, [3, 2] => 2, [2, 6] => 3, [5, 0] => 2, [0, 0] => nil }.each do |(shift, ratio), samples|
      it "shifts every #{samples ? samples * 512 : 32} cycles with shift #{shift} and ratio #{ratio}" do
        start_noise(0xF000, 0x8000 | (shift << 4) | ratio)

        if samples
          bits = (([-120] * 14) + [120, -120]).flat_map { [it] * samples }
          expect(play(16 * samples)).to eq((([0] * (samples - 1)) + bits).first(16 * samples)) # the first shift is a period in
        else
          expect(play(4)).to eq(lfsr_bits(64, 0x4000, 0x6000).each_slice(16).map { it.last == 1 ? 120 : -120 })
        end
      end
    end

    it 'has an envelope like the square channels' do
      start_noise(0x5100, 0x8000 | 0x40)
      play(512)

      expect(play(64).map(&:abs).uniq).to eq([32])
    end

    it 'does not start with the top five envelope bits clear, even when they are set afterwards' do
      start_noise(0x0700, 0x8000 | 0x40)

      bus.write16(0x0400_0078, 0xF000)

      expect([playing?(3), play(2)]).to eq([false, [0, 0]])
    end

    it 'stops when the top five envelope bits are cleared, and stays off when they are set again' do
      start_noise(0xF000, 0x8000 | 0x40)

      bus.write16(0x0400_0078, 0x0700)
      expect([playing?(3), play(2)]).to eq([false, [0, 0]])

      bus.write16(0x0400_0078, 0xF000)
      expect([playing?(3), play(2)]).to eq([false, [0, 0]])
    end

    it 'stops after 64 minus the length steps of 1/256 s with bit 14' do
      start_noise(0xF000 | 62, 0xC000 | 0x40)
      play(191)
      expect(playing?(3)).to be(true)

      play(1)

      expect(playing?(3)).to be(false)
    end
  end

  describe 'mixing' do
    # Left and right
    def levels
      apu.step(512)
      apu.take_samples.map { it / 64 }
    end

    # Channel 1 is at 120 from here for 48 samples
    before do
      start_square(0, 0xF0C0, 0x8000 | square_freq(8))
      play(8)
    end

    4.times do |channel|
      it "sends channel #{channel + 1} to the right with bit #{8 + channel} of SOUNDCNT_L and to the left with bit #{12 + channel}" do
        bus.write16(0x0400_0084, 0) # channel 1 off again
        bus.write16(0x0400_0084, 0x80)
        bus.write16(0x0400_0080, 0x0077 | (1 << (8 + channel)))
        start_square(channel, 0xF0C0, 0x8000 | square_freq(8)) if channel < 2
        start_wave(0x8000 | wave_freq(8), volume: 0x8000) if channel == 2 # empty wave RAM at 3 quarters: -8 * 4 * 3
        start_noise(0xF000, 0x8000 | 0x70) if channel == 3
        expected = [120, 120, -96, -120][channel]
        play(8)

        expect(levels).to eq([0, expected])

        bus.write16(0x0400_0080, 0x0077 | (1 << (12 + channel)))

        expect(levels).to eq([expected, 0])
      end
    end

    it 'adds the channels' do
      start_square(1, 0x50C0, 0x8000 | square_freq(8))
      play(8)

      expect(levels).to eq([160, 160])
    end

    { 0 => 15, 3 => 60, 7 => 120 }.each do |volume, expected|
      it "scales each side by its master volume #{volume} plus 1, in eighths" do
        bus.write16(0x0400_0080, 0xFF07 | (volume << 4))
        expect(levels).to eq([expected, 120])

        bus.write16(0x0400_0080, 0xFF70 | volume)
        expect(levels).to eq([120, expected])
      end
    end

    { 0 => 30, 1 => 60, 2 => 120, 3 => 0 }.each do |code, expected|
      it "scales the PSG to #{expected} of 120 with volume #{code} in SOUNDCNT_H" do
        bus.write16(0x0400_0082, code)

        expect(levels).to eq([expected, expected])
      end
    end

    it 'rounds down, so that a small level below 0 is -1' do
      bus.write16(0x0400_0084, 0)
      bus.write16(0x0400_0084, 0x80)
      bus.write16(0x0400_0080, 0xFF00) # master volume 0: +-8 * 2 / 32
      bus.write16(0x0400_0082, 0x0001)
      start_square(0, 0x1080, 0x8000 | square_freq(1))

      expect(play(8)).to eq(([0] * 4) + ([-1] * 4))
    end

    it 'adds the FIFOs to the PSG and keeps the sum within 10 bits' do
      bus.write16(0x0400_0082, 0x0306) # FIFO A on both sides at full volume
      bus.write32(0x0400_00A0, 0x7F10)
      apu.timer_overflow(0) { nil }
      expect(levels).to eq([120 + 64] * 2)

      apu.timer_overflow(0) { nil }

      expect(levels).to eq([0x1FF] * 2) # 120 + 508
    end

    it 'puts the SOUNDBIAS level under the PSG too' do
      bus.write16(0x0400_0088, 0x180)

      expect(levels).to eq([120 - 0x80] * 2)
    end

    it 'is not disturbed when the master enable is written again while it is on' do
      bus.write16(0x0400_0084, 0x80)

      expect([playing?(0), bus.read16(0x0400_0080), levels]).to eq([true, 0xFF77, [120, 120]])
    end

    it 'is silent while the master enable is off, and the channels are off after it' do
      bus.write16(0x0400_0084, 0)
      expect(levels).to eq([0, 0])

      bus.write16(0x0400_0084, 0x80)
      bus.write16(0x0400_0080, 0xFF77)

      expect([playing?(0), levels]).to eq([false, [0, 0]])
    end
  end
end
