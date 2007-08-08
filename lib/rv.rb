
require 'yaml'
require 'ftools'
require 'highline/import'

=begin rdoc
This class implements all the functionality of Rv. You shouldn't need to use this class directly, rather, use the <tt>rv</tt> executable. However, you may want to override some of the keys in the DEFAULT hash by passing them to Rv.new in the executable. 

Available keys are:
* <tt>'conf_dir'</tt> - the directory of the YAML configuration files.
* <tt>'user'</tt> - the system user used to start the apps.
* <tt>'max_tries'</tt> - the number of retries before giving up on an app (each try takes a half second).
* <tt>'log'</tt> - the path to Rv's own logfile.
* <tt>'ruby'</tt> - a string used to start the Ruby interpreter.

=end

class Rv

  class << self
  
    # Get an Rv parameter from the process environment variables.
    def env(key) #:nodoc:
      value = ENV["RV_#{key.upcase}"]
      raise "Rv key #{key} not found" unless value
      
      if value == value.to_i.to_s 
        value.to_i
      else
        value
      end
    end
    
    # Turn an underscored name into a class reference.
    def classify(string) #:nodoc:
      eval("::" + string.split("_").map do |word| 
        word.capitalize
      end.join)
    end
    
    # Get the canonical pid_file name.
    def pid_file(app = nil, port = nil) #:nodoc:
      "#{app || env('app')}.#{port || env('port')}.pid"
    end
    
  end

  DEFAULTS = {
    'user' => 'httpd',
    'ruby' => '/usr/bin/env ruby',
    'conf_dir' => '/etc/rv', 
    'log' => '/var/log/rv.log',
    'harness' => 'rv_harness.rb',
    'null_stream' => '< /dev/null > /dev/null 2>&1',
    'log_stream' => '< /dev/null >> #{LOG} 2>&1',
    'max_tries' => 10
  }
  
  VALID_ACTIONS = ['start', 'restart', 'stop', 'status', 'setup', 'install']
  
  attr_accessor :options
    
  # Create an Rv instance. You can pass an optional hash to override any key in DEFAULTS.
  def initialize(opts = {})
    extra_keys = opts.keys - DEFAULTS.keys
    raise "Invalid options #{extra_keys.join(', ')}" if extra_keys.any?    

    @options = DEFAULTS.merge(opts)
    options['log_stream'].sub!('#{LOG}', options['log'])
    
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
  
  private
  
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

          pid_file = Rv.pid_file(config['app'], config['port'])  
          pid = get_pid(pid_file)
         
          case action         
            when "status"
              if check_pid(pid)
                note "running"
              elsif pid
                note "has died"
              else
                note "not running"
              end
            when "stop"
              if pid and check_pid(pid)
                # send a hard kill
                system %[nohup sudo -u #{options['user']} kill -9 #{pid} #{options['log_stream']}]                
                # remove the pid file, since we didn't let mongrel to do it
                sleep(0.5)
                unless check_pid(pid)
                  File.delete(pid_file) 
                  running = nil
                  note "stopped"
                else
                  note "failed to stop"
                end
              elsif pid
                note "has already died"
                File.delete pid_file      
              else
                note "not running"
              end
            when "start"
              unless check_pid(pid) 
                env_variables = config.map {|key, value| "RV_#{key.upcase}=#{value}"}.join(" ")
                system %[#{env_variables} nohup sudo -u #{options['user']} #{options['ruby']} #{options['harness']} #{options['log_stream']} &]
                
                # wait for the app to initialize
                tries = 0
                begin
                  sleep(0.5)
                  tries += 1
                  pid = get_pid(pid_file) # reset the pid
                end while tries < options['max_tries'] and !(File.exist?(pid_file) and check_pid(pid))

                if File.exist?(pid_file) and check_pid(pid)
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
    harness_target = "#{this_dir}/#{options['harness']}"

    if !File.exist?(harness_target) or
        (File.open(harness_target).readlines[2] != File.open(harness_source).readlines[2] and
        agree("#{options['harness']} is out-of-date; overwrite? "))
      puts "Installing #{options['harness']} file."
      File.copy harness_source, harness_target
    else
      puts "#{options['harness']} not changed."
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
    
    exit_with "All done. Please double-check the database configuration in '#{options['harness']}';\nthen run 'sudo /etc/init.d/rv start'."
  end
  
  # Installs the 'rv' executable into /etc/init.d.
  def install
    bin_source = "#{File.dirname(__FILE__)}/../bin/rv"
    bin_target = "/etc/init.d/rv"
    begin
      File.copy bin_source, bin_target
      system("chmod u+x #{bin_target}")
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
  
  # system() with debugging output
  def system(string)
    $stderr.puts string if ENV['RV_DEBUG']
    super
  end
  
  private
  
  def get_pid(pid_file)
    File.open(pid_file).readlines.first.chomp rescue nil
  end
  
  def check_pid(pid = nil)
    if pid
      `ps -p #{pid}`.split("\n")[1]
    end
  end
  
end
