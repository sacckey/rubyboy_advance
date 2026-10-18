# frozen_string_literal: true

module RubyboyAdvance
  class Bus
    # 0x04000000-0x0400005F are the LCD registers, owned by the PPU.
    LCD_IO_SIZE = 0x60

    def initialize(rom, ppu)
      @ewram = Array.new(0x40000, 0)
      @iwram = Array.new(0x8000, 0)
      @ioram = Array.new(0x400, 0)
      @rom = rom
      @cartram = Array.new(0x10000, 0)
      @ppu = ppu
    end

    def read(addr)
      case addr >> 24
      when 0x02 then return @ewram[addr & 0x3FFFF]
      when 0x03 then return @iwram[addr & 0x7FFF]
      when 0x04
        offset = addr & 0x3FF
        return offset < LCD_IO_SIZE ? @ppu.read_io(offset) : @ioram[offset]
      when 0x05 then return @ppu.read_palram(addr)
      when 0x06 then return @ppu.read_vram(addr)
      when 0x07 then return @ppu.read_oam(addr)
      when 0x08, 0x09 then return @rom[addr & 0x1FFFFFF] || 0
      when 0x0E then return @cartram[addr & 0xFFFF]
      end

      0xff
    end

    def write(addr, value)
      case addr >> 24
      when 0x02 then @ewram[addr & 0x3FFFF] = value
      when 0x03 then @iwram[addr & 0x7FFF] = value
      when 0x04
        offset = addr & 0x3FF
        offset < LCD_IO_SIZE ? @ppu.write_io(offset, value) : @ioram[offset] = value
      when 0x05 then @ppu.write_palram(addr, value)
      when 0x06 then @ppu.write_vram(addr, value)
      when 0x07 then @ppu.write_oam(addr, value)
      when 0x0E then @cartram[addr & 0xFFFF] = value
      end

      nil
    end

    def read16(addr)
      read(addr) + (read(addr + 1) << 8)
    end

    def write16(addr, value)
      write(addr, value & 0xFF)
      write(addr + 1, (value >> 8) & 0xFF)
    end

    def read32(addr)
      read16(addr) + (read16(addr + 2) << 16)
    end

    def write32(addr, value)
      write16(addr, value & 0xFFFF)
      write16(addr + 2, (value >> 16) & 0xFFFF)
    end
  end
end
