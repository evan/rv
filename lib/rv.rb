
require 'yaml'
require 'ftools'
require 'highline/import'

# This class implements all the functionality of Rv. You shouldn't need to use this class directly, rather, use the <tt>rv</tt> executable.
class Rv

  class << self
  
    # Get an Rv parameter from the process environment variables.
    def env(key)
      value = ENV["#{RV}_#{key.upcase}"]
      raise "Rv key #{key} not found" unless value
      
      if value == value.to_i.to_s 
        value.to_i
      else
        value
      end
    end
    
    # Turn an underscored name into a class reference.
    def classify(string)
      eval("::" + string.split("_").map do |word| 
        word.capitalize
      end.join)
    end
    
    # Get the canonical pid_file name.
    def pid_file(app = nil, port = nil)
      "#{app || env('app')}.#{port || env('port')}.pid"
    end
    
  end

  DEFAULTS = {
    'user' => 'httpd',
    'ruby' => '/usr/bin/env ruby',
    'pidfile' => 'application.pid',
    'conf_dir' => '/etc/rv', 
    'harness' => 'rv_harness.rb',
    'log' => '/var/log/rv.log',
    'null_stream' => "< /dev/null > /dev/null 2>&1",
    'log_stream' => "< /dev/null >> 'log' 2>&1"
  }
  
  VALID_ACTIONS = ['start', 'restart', 'stop', 'status', 'setup', 'install']
  
  attr_accessor :options
    
  # Create an Rv instance. You can pass an optional hash to override any key in DEFAULTS.
  def initialize(opts = {})
    extra_keys = opts.keys - DEFAULTS.keys
    raise "Invalid options #{extra_keys.join(', ')}" if extra_keys.any?    

    @options = DEFAULTS.merge(opts)
    options['log_stream'].sub!("log", options['log'])
    
    # make sure the log exists
    begin 
      unless File.exist? options['log']
        File.open(options['log'], "w") {}
      end
    rescue Errno::EACCES
      exit_with "Couldn't write to logfile '#{options['log']}'"
    end
    system "chown #{options['user']} #{options['log']} #{options['null_stream']}"
    system "chgrp #{options['user']} #{options['log']} #{options['null_stream']}"

  end
    
  # Perform any action in VALID_ACTIONS. Defaults to running against all applications. Pass a specific app name as <tt>match</tt> if this is not what you want.
  def perform(action, match = '*')
    exit_with "No action given." unless action
    exit_with "Invalid action '#{action}'." unless VALID_ACTIONS.include? action
    
    case action 
      when "restart"
        daemon("stop", match)
        daemon("start", match)
      when "install"
        install
      when "setup"
        setup
      else
        daemon(action, match)
    end
    
  end
  
  # Runs a daemon action. Only called from <tt>perform</tt>.
  def daemon(action, match)
    filenames = Dir["#{options['conf_dir']}/#{match}.yml"]
    exit_with("No applications found for '#{match}' in #{options['conf_dir']}/") if filenames.empty?
    
    # Examine matching applications
    filenames.each do |filename|      

      real_config = YAML.load_file(filename)
      puts "Application #{real_config['app']}:"
      
      Dir.chdir real_config['dir'] do

        # cluster loop
        (real_config['cluster_size'] or 1).times do |cluster_index|
          config = real_config.dup
          @port = config['port'] += cluster_index

          pidfile = Rv.pid_file(config['app'], config['port'])  
          pid = File.open(pidfile).readlines.first.chomp rescue nil
          running = pid ? `ps -p #{pid}`.split("\n")[1] : nil
         
          case action         
            when "status"
              if running
                note "running"
              elsif pid
                note "has died"
              else
                note "not running"
              end
            when "stop"
              if pid and running
                system %[nohup su -c "kill -9 #{pid} #{options['null_stream']}" #{options['user']} #{options['log_stream']}]
                running = nil
                note "stopped"
              elsif pid
                note "not running"
                File.delete pidfile            
              else
                note "pid file #{pidfile.inspect} not found. Application was probably not running."
              end
            when "start"
              unless running 
                env_variables = config.map {|key, value| "RV_#{key.upcase}=#{value}"}.join(" ")
                system %[nohup su -c "#{env_variables} #{options['ruby']} #{options['harness']} #{options['null_stream']}" #{options['user']} #{options['log_stream']} &]
                sleep(2)
                if File.exist? pidfile
                  note "started"
                else
                  note "failed to start"
                end
              else
                note "already running"
              end
          end  
          
        end
      end
    end    
  end

  # Sets up a Camping app for Rv.
  def setup
    this_dir = `pwd`.chomp
    app_name = this_dir.split("/").last
    harness_source = "#{File.dirname(__FILE__)}/rv_harness.rb"
    harness_target = "#{this_dir}/rv_harness.rb"

    if !File.exist?(harness_target) or
        (File.open(harness_target).readlines[2] != File.open(harness_source).readlines[2] and
        agree("rv_harness.rb is out-of-date; overwrite? "))
      puts "Installing rv_harness.rb file."
      File.copy harness_source, harness_target
    else
      puts "rv_harness.rb not changed."
    end
    
    defaults = {
      'dir' => this_dir,
      'app' => app_name,
      'port' => 4000,
      'cluster_size' => 1
    }

    # get the application name    
    default_file = current_file = "#{defaults['app']}.rb"  

    begin
      current_file = ask("File of Camping app: ") do |q| 
        q.default = default_file
      end
    end while !File.exist?(current_file)            

    defaults['app'] = current_file.split("/").last.gsub(".rb", "")
    
    # get the port name
    current_port = ask("Port number to listen on: ") do |q|
      q.default = defaults['port']
    end while current_port.to_i.to_s != current_port
    
    defaults['port'] = current_port.to_i
    
    # get the cluster size
    current_cluster_size = ask("Listener cluster size (1 recommended): ") do |q|
      q.default = defaults['cluster_size']
    end while current_cluster_size.to_i.to_s != current_cluster_size or current_cluster_size.to_i < 1
    
    defaults['cluster_size'] = current_cluster_size.to_i
    
    # write the config file
    config_location = "#{options['conf_dir']}/#{defaults['app']}.yml"  
    puts "Writing configuration to '#{config_location}'."      

    begin
      unless File.exist? options['conf_dir']
        Dir.mkdir options['conf_dir']
      end
      File.open(config_location, "w") do |file|
        file.write defaults.to_yaml
      end
    rescue Errno::EACCES
      exit_with "Couldn't write to '#{options['conf_dir']}'. Please rerun with 'sudo'."
    end
    
    exit_with "All done. Please double-check the database configuration in 'rv_harness.rb';\nthen run '/etc/init.d/rv start'."
  end
  
  # Installs the 'rv' executable into /etc/init.d.
  def install
    bin_source = "#{File.dirname(__FILE__)}/../bin/rv"
    bin_target = "/etc/init.d/rv"
    begin
      File.copy bin_source, bin_target
    rescue Errno::EACCES
      exit_with "Couldn't write to '#{bin_target}'. Please rerun with 'sudo'."
    end
    exit_with "Installed 'rv' executable to '#{bin_target}'."
  end  

  # Exits with a message.  
  def exit_with(msg)
    puts msg
    exit
  end
  
  # Prints a message along with the current port.
  def note(msg)
    puts "  #{msg.capitalize} (#{@port})"
  end
  
  
end
