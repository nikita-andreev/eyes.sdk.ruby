# require_relative '../lib/eyes_selenium'
require 'eyes_images'
require 'logger'

require 'openssl'
OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

eyes = Applitools::Images::Eyes.new
eyes.api_key = ENV['APPLITOOLS_API_KEY']
eyes.log_handler = Logger.new(STDOUT)
# eyes.proxy = Applitools::Connectivity::Proxy.new 'http://localhost:9999'


viber_home_image_bytes = File.read('./images/viber-home.png', mode: 'rb')
viber_home_image = Applitools::Screenshot.from_datastream viber_home_image_bytes

begin
  eyes.test(app_name: 'Eyes.Java', test_name: 'home1') do
    target = Applitools::Images::Target.path('./images/viber-home.png').ignore(Applitools::Region.new(10, 10, 30, 30))
    eyes.check('entire image', target)
    target = target.region(Applitools::Region.new(1773, 372, 180, 220))
    eyes.check('Bada region', target)
    eyes.add_mouse_trigger(:click, Applitools::Region::EMPTY, Applitools::Location.new(1866, 500))
    target = Applitools::Images::Target.path('./images/viber-bada.png')
    eyes.check('Bada entire image', target)
  end
rescue
end

eyes.test(app_name: 'Eyes.Java', test_name: 'home2') do
  target = Applitools::Images::Target.screenshot(viber_home_image)
  eyes.check('', target)
  target = Applitools::Images::Target.path('./images/viber-bada.png')
  eyes.check('', target)
end
