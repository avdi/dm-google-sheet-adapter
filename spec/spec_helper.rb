require 'rubygems'
require 'spork'

Spork.prefork do
  # Loading more in this block will cause your tests to run faster. However,
  # if you change any configuration or code from libraries loaded here, you'll
  # need to restart spork for it take effect.

  require 'bundler/setup'

  $LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
  $LOAD_PATH.unshift(File.dirname(__FILE__))
  require 'rspec'
  require 'vcr'

  RSpec.configure do |config|
    config.extend VCR::RSpec::Macros
  end

  # Requires supporting files with custom matchers and macros, etc,
  # in ./support/ and its subdirectories.
  Dir["#{File.dirname(__FILE__)}/support/**/*.rb"].each {|f| require f}


  VCR.config do |c|
    c.cassette_library_dir = File.expand_path(
      '../vcr_cassettes',
      File.dirname(__FILE__))
    c.stub_with :faraday
    c.allow_http_connections_when_no_cassette = false
    c.default_cassette_options = {
      :record => :once,
      :erb    => true
    }
  end
end

Spork.each_run do
  # This code will be run each time you run your specs.

  require 'dm-google-sheet-adapter'
end


