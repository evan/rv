require 'yaml'

class Rv

  DEFAULTS = {
    'user' => 'httpd',
    'ruby' => '/usr/bin/env ruby',
    'pidfile' => 'mongrel.pid',
    'conf_dir' => '/etc/rv', 
    'harness' => 'rv_harness.rb',
    'log' => '/var/log/rv.log',
    'null_stream' => "< /dev/null > /dev/null 2>&1",
    'log_stream' => "< /dev/null >> 'log' 2>&1"
  }
  
  VALID_ACTIONS = ['start', 'restart', 'stop', 'status', 'setup']
  
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
  end
    
  # Perform any action in VALID_ACTIONS. Defaults to running against all applications. Pass a specific app name as <tt>match</tt> if this is not what you want.
  def perform(action, match = '*')
    exit_with "No action given." unless action
    exit_with "Invalid action '#{action}'." unless VALID_ACTIONS.include? action
    
    # Restart is a composite task
    if action == "restart"
      perform("stop", match)
      perform("start", match)
      return
    end
    
    # Setup is a special task
    if action == "setup"
      
      return
    end
    
    # Other tasks
    filenames = Dir["#{options['conf_dir']}/#{match}.yml"]
    exit_with("No applications found for '#{match}' in #{options['conf_dir']}/") if filenames.empty?
    
    # Examine matching applications
    filenames.each do |filename|      
      config = YAML.load_file(filename)
      application = filename[/.*\/(.+)\.yml/, 1]
      puts "Application #{application}:"
  
      Dir.chdir config['dir'] do
            
        pidfile = File.exists?("#{application}.pid") ? "#{application}.pid" : options['pidfile']
        pid = File.open(pidfile).readlines.first.chomp rescue nil
        running = pid ? `ps -p #{pid}`.split("\n")[1] : nil
        
        case action         
          when "status"
            if running
              puts "  Running."
            elsif pid
              puts "  Has died."
            else
              puts "  Not running."
            end
          when "stop"
            if pid and running
              system %[nohup su -c "kill -9 #{pid} #{options['null_stream']}" #{options['user']} #{options['log_stream']}]
              running = nil
              puts "  Stopped."
            elsif pid
              puts "  Not running."
              File.delete pidfile            
            else
              puts "  Pid file #{pidfile.inspect} not found (probably not running to begin with)"
            end
          when "start"
            unless running 
              puts "  Started."
              system %[nohup su -c "#{options['ruby']} #{options['harness']} #{config['opts'].join ' '} #{options['null_stream']}" #{options['user']} #{options['log_stream']} &]       
            else
              puts "  Already running."
            end
        end  
        
      end
    end    
  end
  
  private
  
  def exit_with(msg)
    puts msg
    exit
  end
  
end
