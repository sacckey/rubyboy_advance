# frozen_string_literal: true

module RubyboyAdvance
  class Bus
    attr_reader :interrupt
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

    def initialize(rom, bios, ppu, cartram, interrupt, timer, keypad)
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
      @cycles = 0
      @next_addr = nil
      @nonseq16 = COSTS16.dup
      @seq16 = COSTS16.dup
      @nonseq32 = COSTS32.dup
      @seq32 = COSTS32.dup
      update_wait_costs
    end

    def take_cycles
      cycles = @cycles
      @cycles = 0
      cycles
    end

    # ponytail: sequential is guessed from the address, so every DMA unit counts as non-sequential
    def read(addr)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 1
      raw_read(addr)
    end

    def write(addr, value)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 1
      raw_write(addr, value)
    end

    def read16(addr)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 2
      raw_read16(addr)
    end

    def write16(addr, value)
      @cycles += (addr == @next_addr ? @seq16 : @nonseq16)[(addr >> 24) & 0xFF]
      @next_addr = addr + 2
      raw_write16(addr, value)
    end

    def read32(addr)
      @cycles += (addr == @next_addr ? @seq32 : @nonseq32)[(addr >> 24) & 0xFF]
      @next_addr = addr + 4
      raw_read32(addr)
    end

    def write32(addr, value)
      @cycles += (addr == @next_addr ? @seq32 : @nonseq32)[(addr >> 24) & 0xFF]
      @next_addr = addr + 4
      raw_write32(addr, value)
    end

    # Runs the DMA channels waiting for :vblank or :hblank, which the PPU yields from step
    def run_dma(timing)
      @dma.trigger(timing, self)
    end

    def hint_eeprom_size(count)
      @cartram.hint_size(count) if @eeprom
    end

    private

    def raw_read(addr)
      case addr >> 24
      when 0x00 then return @bios[addr & 0x3FFF]
      when 0x02 then return @ewram[addr & 0x3FFFF]
      when 0x03 then return @iwram[addr & 0x7FFF]
      when 0x04
        offset = addr & 0x3FF
        return @ppu.read_io(offset) if offset < LCD_IO_SIZE

        case offset
        when 0x100..0x10F then return @timer.read(offset)
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

    def raw_write(addr, value)
      case addr >> 24
      when 0x05 then raw_write16(addr, value * 0x0101)
      when 0x06 then raw_write16(addr, value * 0x0101) if @ppu.bg_vram?(addr)
      when 0x07 then nil
      else write8(addr, value)
      end
    end

    def raw_read16(addr)
      return @cartram.read_bit if eeprom?(addr)

      case addr >> 24
      when 0x0E, 0x0F then raw_read(addr) * 0x0101
      else
        addr &= ~1
        raw_read(addr) + (raw_read(addr + 1) << 8)
      end
    end

    def raw_write16(addr, value)
      return @cartram.write_bit(value) if eeprom?(addr)

      case addr >> 24
      when 0x0E, 0x0F then write8(addr, (value >> ((addr & 1) << 3)) & 0xFF)
      else
        addr &= ~1
        write8(addr, value & 0xFF)
        write8(addr + 1, (value >> 8) & 0xFF)
      end
    end

    def raw_read32(addr)
      case addr >> 24
      when 0x0E, 0x0F then raw_read(addr) * 0x0101_0101
      else
        addr &= ~3
        raw_read16(addr) + (raw_read16(addr + 2) << 16)
      end
    end

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
      @eeprom && (addr >> 24).between?(0x08, 0x0D) && (addr & @eeprom_mask) == @eeprom_mask
    end

    def write8(addr, value)
      case addr >> 24
      when 0x02 then @ewram[addr & 0x3FFFF] = value
      when 0x03 then @iwram[addr & 0x7FFF] = value
      when 0x04
        offset = addr & 0x3FF
        return @ppu.write_io(offset, value) if offset < LCD_IO_SIZE

        case offset
        when 0x100..0x10F then @timer.write(offset, value)
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
