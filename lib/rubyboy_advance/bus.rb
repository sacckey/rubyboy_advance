# frozen_string_literal: true

module RubyboyAdvance
  class Bus
    # Types Spinel cannot work out by itself: these and the signatures below (spinel/README.md)
    # @rbs @cycles: Integer
    # @rbs @next_addr: Integer
    # @rbs @until_event: Integer
    # @rbs @instruction_start: Integer

    attr_reader :interrupt, :cycles
    attr_writer :cpu

    # The ROM and the cartridge RAM are filled in from WAITCNT
    COSTS16 = Array.new(0x100) { |i| i == 0x02 ? 3 : 1 }.freeze

    COSTS32 = Array.new(0x100) do |i|
      case i
      when 0x02 then 6
      when 0x05, 0x06 then 2
      else 1
      end
    end.freeze

    # WAITCNT values to cycles (NanoBoyAdvance timing.cc)
    WAIT_NONSEQ = [5, 4, 3, 9].freeze
    WAIT_SEQ = [[3, 2], [5, 2], [9, 2]].freeze

    # 0x04000000-0x0400005F are the LCD registers, owned by the PPU.
    LCD_IO_SIZE = 0x60

    def initialize(rom, bios, ppu, cartram, interrupt, timer, keypad, apu)
      @ewram = Array.new(0x40000, 0)
      @iwram = Array.new(0x8000, 0)
      @ioram = Array.new(0x400, 0)
      @rom = rom
      @cartram = cartram
      @eeprom = cartram.is_a?(Eeprom)
      # NanoBoyAdvance rom.hh
      @eeprom_mask = rom.size > 0x0100_0000 ? 0x01FF_FF00 : 0x0100_0000
      @ppu = ppu
      @interrupt = interrupt
      @bios = bios
      @dma = Dma.new
      @timer = timer
      @keypad = keypad
      @apu = apu
      @cycles = 0
      @next_addr = -1 # no address follows the last access
      @until_event = 0
      @instruction_start = 0 # in cycles not yet taken; 0 unless the CPU is running on to an event
      @nonseq16 = COSTS16.dup
      @seq16 = COSTS16.dup
      @nonseq32 = COSTS32.dup
      @seq32 = COSTS32.dup
      update_wait_costs
    end

    # At most limit of the last instruction's, with all of those before it; the rest stay for the next call
    # @rbs (?Integer) -> Integer
    def take_cycles(limit = @cycles)
      cycles = @instruction_start + limit
      cycles = @cycles if @cycles < cycles
      @cycles -= cycles
      @instruction_start = 0
      cycles
    end

    # How long a halted CPU can sleep: nothing changes until the PPU, a timer or the APU next does something
    def cycles_to_event
      [@ppu.cycles_to_event, @timer.cycles_to_overflow, @apu.cycles_to_sample].min
    end

    # Until then the devices would only count the time, so the CPU runs on and they are stepped once
    def await_event
      @until_event = cycles_to_event
    end

    # Asked after each instruction
    # @rbs () -> bool
    def event_due?
      return true if @cycles >= @until_event

      @instruction_start = @cycles
      false
    end

    # Time without a bus access; the access after it is never sequential
    # @rbs (?Integer) -> void
    def idle(cycles = 1)
      @cycles += cycles
      @next_addr = -1
    end

    # ponytail: sequential is guessed from the address unless the caller says, as the DMA does
    # @rbs (Integer) -> Integer
    def read(addr)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 1
      raw_read(addr)
    end

    # @rbs (Integer, Integer) -> void
    def write(addr, value)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 1
      raw_write(addr, value)
    end

    # The two work RAMs and the ROM take nearly every 16- and 32-bit access, so those go straight to their arrays
    # @rbs (Integer, ?bool) -> Integer
    def read16(addr, seq = addr == @next_addr)
      area = addr >> 24
      @cycles += (seq ? @seq16 : @nonseq16)[area & 0xFF]
      @next_addr = addr + 2
      case area
      when 0x03
        i = addr & 0x7FFE
        @iwram[i] | (@iwram[i + 1] << 8)
      when 0x02
        i = addr & 0x3_FFFE
        @ewram[i] | (@ewram[i + 1] << 8)
      when 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D
        return @cartram.read_bit if @eeprom && eeprom?(addr)

        i = addr & 0x1FF_FFFE
        (@rom[i] || 0) | ((@rom[i + 1] || 0) << 8)
      else raw_read16(addr)
      end
    end

    # @rbs (Integer, Integer, ?bool) -> void
    def write16(addr, value, seq = addr == @next_addr)
      area = addr >> 24
      @cycles += (seq ? @seq16 : @nonseq16)[area & 0xFF]
      @next_addr = addr + 2
      case area
      when 0x03
        i = addr & 0x7FFE
        @iwram[i] = value & 0xFF
        @iwram[i + 1] = (value >> 8) & 0xFF
      when 0x02
        i = addr & 0x3_FFFE
        @ewram[i] = value & 0xFF
        @ewram[i + 1] = (value >> 8) & 0xFF
      else raw_write16(addr, value)
      end
    end

    # @rbs (Integer, ?bool) -> Integer
    def read32(addr, seq = addr == @next_addr)
      area = addr >> 24
      @cycles += (seq ? @seq32 : @nonseq32)[area & 0xFF]
      @next_addr = addr + 4
      case area
      when 0x03
        i = addr & 0x7FFC
        @iwram[i] | (@iwram[i + 1] << 8) | (@iwram[i + 2] << 16) | (@iwram[i + 3] << 24)
      when 0x02
        i = addr & 0x3_FFFC
        @ewram[i] | (@ewram[i + 1] << 8) | (@ewram[i + 2] << 16) | (@ewram[i + 3] << 24)
      when 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D
        return raw_read32(addr) if @eeprom && eeprom?(addr)

        i = addr & 0x1FF_FFFC
        (@rom[i] || 0) | ((@rom[i + 1] || 0) << 8) | ((@rom[i + 2] || 0) << 16) | ((@rom[i + 3] || 0) << 24)
      else raw_read32(addr)
      end
    end

    # @rbs (Integer, Integer, ?bool) -> void
    def write32(addr, value, seq = addr == @next_addr)
      area = addr >> 24
      @cycles += (seq ? @seq32 : @nonseq32)[area & 0xFF]
      @next_addr = addr + 4
      case area
      when 0x03
        i = addr & 0x7FFC
        @iwram[i] = value & 0xFF
        @iwram[i + 1] = (value >> 8) & 0xFF
        @iwram[i + 2] = (value >> 16) & 0xFF
        @iwram[i + 3] = (value >> 24) & 0xFF
      when 0x02
        i = addr & 0x3_FFFC
        @ewram[i] = value & 0xFF
        @ewram[i + 1] = (value >> 8) & 0xFF
        @ewram[i + 2] = (value >> 16) & 0xFF
        @ewram[i + 3] = (value >> 24) & 0xFF
      else raw_write32(addr, value)
      end
    end

    # Runs the DMA channels waiting for timing: :vblank or :hblank from the PPU, :fifo_a or :fifo_b from the APU
    def run_dma(timing)
      @dma.trigger(timing, self)
    end

    def hint_eeprom_size(count)
      @cartram.hint_size(count) if @eeprom
    end

    private

    # @rbs (Integer) -> Integer
    def raw_read(addr)
      case addr >> 24
      when 0x00 then return @bios[addr & 0x3FFF]
      when 0x02 then return @ewram[addr & 0x3FFFF]
      when 0x03 then return @iwram[addr & 0x7FFF]
      when 0x04
        offset = addr & 0x3FF
        return @ppu.read_io(offset) if offset < LCD_IO_SIZE

        case offset
        when 0x100..0x10F then return @timer.read(offset, @instruction_start)
        when 0x060..0x09F then return @apu.read(offset)
        when 0x200, 0x201, 0x202, 0x203, 0x208, 0x209 then return @interrupt.read(offset)
        when 0x0B0..0x0DF then return @dma.read(offset)
        when 0x130, 0x131 then return @keypad.read(offset)
        else return @ioram[offset]
        end
      when 0x05 then return @ppu.read_palram(addr)
      when 0x06 then return @ppu.read_vram(addr)
      when 0x07 then return @ppu.read_oam(addr)
      when 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D then return @rom[addr & 0x1FFFFFF] || 0
      when 0x0E, 0x0F then return @cartram.read(addr & 0xFFFF)
      end

      0xff
    end

    # @rbs (Integer, Integer) -> void
    def raw_write(addr, value)
      case addr >> 24
      when 0x05 then raw_write16(addr, value * 0x0101)
      when 0x06 then raw_write16(addr, value * 0x0101) if @ppu.bg_vram?(addr)
      when 0x07 then nil
      else write8(addr, value)
      end
    end

    # @rbs (Integer) -> Integer
    def raw_read16(addr)
      return @cartram.read_bit if @eeprom && eeprom?(addr)

      case addr >> 24
      when 0x0E, 0x0F then raw_read(addr) * 0x0101
      else
        addr &= ~1
        raw_read(addr) + (raw_read(addr + 1) << 8)
      end
    end

    # @rbs (Integer, Integer) -> void
    def raw_write16(addr, value)
      return @cartram.write_bit(value) if @eeprom && eeprom?(addr)

      case addr >> 24
      when 0x0E, 0x0F then write8(addr, (value >> ((addr & 1) << 3)) & 0xFF)
      else
        addr &= ~1
        write8(addr, value & 0xFF)
        write8(addr + 1, (value >> 8) & 0xFF)
      end
    end

    # @rbs (Integer) -> Integer
    def raw_read32(addr)
      case addr >> 24
      when 0x0E, 0x0F then raw_read(addr) * 0x0101_0101
      else
        addr &= ~3
        raw_read16(addr) + (raw_read16(addr + 2) << 16)
      end
    end

    # @rbs (Integer, Integer) -> void
    def raw_write32(addr, value)
      case addr >> 24
      when 0x0E, 0x0F then write8(addr, (value >> ((addr & 3) << 3)) & 0xFF)
      else
        addr &= ~3
        raw_write16(addr, value & 0xFFFF)
        raw_write16(addr + 2, (value >> 16) & 0xFFFF)
      end
    end

    # ponytail: no prefetch buffer (WAITCNT bit 14) and no N access at each 128 KB of ROM
    def update_wait_costs
      waitcnt = @ioram[0x204] | (@ioram[0x205] << 8)

      3.times do |i|
        nonseq = WAIT_NONSEQ[(waitcnt >> (2 + (i * 3))) & 3]
        seq = WAIT_SEQ[i][waitcnt[4 + (i * 3)]]
        [0x08 + (i * 2), 0x09 + (i * 2)].each do |area|
          @nonseq16[area] = nonseq
          @seq16[area] = seq
          @nonseq32[area] = nonseq + seq # the ROM bus is 16 bits wide: one N and one S
          @seq32[area] = seq * 2
        end
      end

      sram = WAIT_NONSEQ[waitcnt & 3]
      [0x0E, 0x0F].each { |area| @nonseq16[area] = @seq16[area] = @nonseq32[area] = @seq32[area] = sram }
    end

    # ponytail: 16-bit accesses only
    def eeprom?(addr)
      area = addr >> 24
      area >= 0x08 && area <= 0x0D && (addr & @eeprom_mask) == @eeprom_mask
    end

    # @rbs (Integer, Integer) -> void
    def write8(addr, value)
      case addr >> 24
      when 0x02 then @ewram[addr & 0x3FFFF] = value
      when 0x03 then @iwram[addr & 0x7FFF] = value
      when 0x04
        offset = addr & 0x3FF
        return @ppu.write_io(offset, value) if offset < LCD_IO_SIZE

        @until_event = 0 # the write may bring the next event closer or halt the CPU
        case offset
        when 0x100..0x10F then @timer.write(offset, value, @instruction_start)
        when 0x060..0x0A7 then @apu.write(offset, value)
        when 0x130, 0x131 then nil
        when 0x200, 0x201, 0x202, 0x203, 0x208, 0x209 then @interrupt.write(offset, value)
        when 0x204, 0x205
          @ioram[offset] = value
          update_wait_costs
        when 0x301 then @interrupt.write(offset, value) if @cpu.in_bios? # HALTCNT only works from the BIOS
        when 0x0B0..0x0DF then @dma.write(offset, value, self)
        else @ioram[offset] = value
        end
      when 0x05 then @ppu.write_palram(addr, value)
      when 0x06 then @ppu.write_vram(addr, value)
      when 0x07 then @ppu.write_oam(addr, value)
      when 0x0E, 0x0F then @cartram.write(addr & 0xFFFF, value)
      end

      nil
    end
  end
end
