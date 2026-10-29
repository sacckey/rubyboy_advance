# frozen_string_literal: true

RSpec.describe 'Flash chip ID' do
  def send_command(flash, command)
    flash.write(0x5555, 0xAA)
    flash.write(0x2AAA, 0x55)
    flash.write(0x5555, command)
  end

  {
    RubyboyAdvance::Flash => [0x32, 0x1B],
    RubyboyAdvance::Flash128 => [0x62, 0x13]
  }.each do |flash_class, id|
    it "#{flash_class} reads its chip ID in ID mode and the data again after F0" do
      flash = flash_class.new

      send_command(flash, 0x90)
      expect([flash.read(0), flash.read(1)]).to eq(id)

      send_command(flash, 0xF0)
      expect([flash.read(0), flash.read(1)]).to eq([0xFF, 0xFF])
    end
  end
end
