
# Example mongrel harness for Camping apps with Rv
require 'rubygems'
require 'mongrel'
require 'mongrel/camping'

# Whatever options you want passed in from the 'opts' key in the .yml configuration
app_name, port = ARGV[0], ARGV[1].to_i

# Load the Camping app
require app_name 
app = eval(app_name.split("_").map {|word| word.capitalize}.join)

# Configure your database
app::Models::Base.establish_connection(
  :adapter => 'mysql',
  :database => app_name,
  :username => 'root'
)

#app::Models::Base.logger = Logger.new('mongrel.log')
app::Models::Base.threaded_connections = false
app.create

Mongrel::Configurator.new :host => '127.0.0.1', :pid_file => 'mongrel.pid' do
  
  listener :port => port do    
    # setup routes
    uri '/', :handler => Mongrel::Camping::CampingHandler.new(app)
    uri '/static/', :handler => Mongrel::DirHandler.new("static/")    
    uri '/favicon.ico', :handler => Mongrel::Error404Handler.new('')

    # bootstrap the server
    setup_signals
    run
    write_pid_file
    log "#{app_name} available at #{interface}:#{port}"
    join
  end
    
end

