#! /usr/bin/ruby
require 'pp'
require 'optparse'
require 'ostruct'
require 'logger'

@log = Logger.new(STDOUT)
@log.level = Logger::INFO

options = OpenStruct.new
options.dev = []

OptionParser.new do |opts|
  opts.banner = "Usage: example.rb [options]"

  opts.on("-v", "--[no-]verbose", "Run verbosely") do |v|
    options[:verbose] = v
  end
  
  opts.on("-d", "--dev [DEVICEPATH]", "device to resize") do |dev|
    if dev  !~ /\/dev\/\D+$/
      raise OptionParser::InvalidOption, "#{dev}"
    end
    options.dev << dev
  end
  opts.on("-v", "--verbose", "Run verbosely without make any change") do |v|
    @log.level = Logger::DEBUG
    options.verbose = v
  end
  # Another typical switch to print the version.
  opts.on_tail("--version", "Show version") do
    puts "Dev extender v1.0.0"
    exit
  end
end.parse!


Default_fs = 'ext4'  # Default partition type
Suported_fs = ['ext', 'ext2', 'ext3', 'ext4']
Maxlogical = 4       # logical partition has a number greater than 4

#call parted command with parameter and get output
def parted(*p)
  parameter = p.join(' ')
  @log.debug "exec: parted #{parameter}"
  output = %x[ parted #{parameter} ]
    unless $? == 0
    @log.error "Fail!! #{output}"
    return nil;
  end
  return output.split(";\n")
end

def is_mounted(dev, partition)
  #dev_name = dev.sub('/dev/', '')
  #puts "dev_name: #{dev_name}"
  output = %x[lsblk -Pf #{dev}#{partition}]
  mountpoint= /MOUNTPOINT=\"(.*)\"/.match(output)
  return mountpoint[1] if not mountpoint[1].empty?
  return false
end

def is_in_use(dev, logical)
  (Maxlogical+1 .. logical).each {|dev_num|
    output = %x[lsblk -Pf #{dev}#{dev_num}]
    mountpoint= /MOUNTPOINT=\"(.*)\"/.match(output)
    if not mountpoint[1].empty?
      @log.debug "patition #{logical} is mounted!."
      return mountpoint[1]
    end 
  }
  @log.debug "patition #{logical} is not mounted."
  return false
end

#get free space in device
def get_free(dev)
   output = parted(dev, 'unit', 'mb','print', 'free', '-m')
   unless $? == 0
       return nil;
   end
   fields = output.last.strip.split(':')  # type of last partition
   @log.debug fields
   if fields.last == 'free'
     return fields[3]   # return free space
   elsif fields.last == ' unrecognised disk label'
     return nil       # Disk don't have a label
   else
     return "0MB"         # No free space
   end
end

#get device list in system
def get_devs()
  output = parted('-l', '-m')
  devs = []
  output.each_with_index { |line, i|
    line.strip!
    if line == 'BYT'
      device = output[i+1].split(':')[0]
      devs.push(device)
      next
    end
    fields = line.split(':')
    if fields[0] == 'Error'
      devs.push(fields[1].strip)
    end
  }
  return devs
end

def resize_disk (dev)
  output = parted(dev, '-m', 'print', 'free')
  logical = 4
  primary = 0
  confirm = ''
  output.reverse.each { |i|
    fields = i.strip.split(':')
    if fields.last == 'free'
      # none
    else
      # it is the first non-free partition 
      if fields.first =~ /^\d/
        devnum = fields.first.to_i
      else
        # there is no patition previous to free space
        @log.debug "parted #{dev} mkpart primary #{Default_fs} 1 100%"
        @log.debug 'mkfs.#{Default_fs} #{dev}1'
        parted(dev, 'mkpart', 'primary', Default_fs, '1', '100%') unless @log.debug?
        %x[mkfs.#{Default_fs} #{dev}1 2> /dev/null]               unless @log.debug?
        return true
      end

      if devnum > logical
        if not Suported_fs.include?(fields.last)
          @log.error "Filesystem not supported in #{dev}#{devnum}: #{fields.last}"
          exit 1
        end
        logical = devnum
      elsif devnum <= Maxlogical
        primary = devnum
        @log.debug "resize primary on #{dev}: #{primary} confirm:#{confirm}"
        confirm = ''
        confirm = 'yes' if is_in_use(dev, logical) # parted ask for confirmation
        @log.info "#{dev}#{primary} is primary and should be extende before logical."
        @log.debug "exec: parted #{dev} resizepart #{primary} #{confirm} 100%"
        output = parted(dev, 'resizepart', primary, confirm, '100%') unless @log.debug?
        if not output.nil? and logical > 4
          @log.info "resize logical partition on #{dev}: #{logical}"
          confirm = ''
          confirm = 'yes' if is_mounted(dev, logical) # parted ask for confirmation
          @log.debug "exec: parted #{dev} resizepart #{logical} #{confirm} 100%"
          output = parted(dev,  'resizepart' , logical, confirm, '100%') unless @log.debug?
          if not output.nil?
            @log.info "resizing filesystem in #{dev}#{logical}"
            @log.debug "exec : resize2fs #{dev}#{logical}"
            %x[resize2fs #{dev}#{logical}] unless @log.debug?
          else
            @log.error "Error2 executing parted. Output was: #{output}"
          end
        elsif output.nil?
          @log.error "Error1 executing parted. Output was: #{output}"
        end
        return true
      end
    end
  }
end

if options.dev.empty?
  dv = get_devs()
else
  dv = options.dev
end
@log.debug("Number of devices " + dv.join(','))

dv.each {|d|
   print 
   free = get_free(d)
   if not free                   # New disk!!!
     @log.info d + " don't have partition. Format disk know!"
     parted(d, 'mklabel', 'msdos')                           unless @log.debug?
     parted(d, 'mkpart', 'primary', default_fs, '1', '100%') unless @log.debug?
     %x[mkfs.#{Default_fs} #{d}1 2> /dev/null]               unless @log.debug?
   elsif free[/(\d+)/].to_i > 0  # resize!!
     @log.info d + " have free space: #{free}"
     resize_disk (d)
   elsif free == '0MB'           # No available space
     @log.warn d + " don't have free space for you: #{free}"
   end
}
