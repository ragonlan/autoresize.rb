#! /usr/bin/ruby
require 'pp'

Default_fs = 'ext4'  # Default partition type
Maxlogical = 4       # logical partition has a number greater than 4

#call parted command with parameter and get output
def parted(*p)
  parameter = p.join(' ')
  puts "exec: parted #{parameter}"
  output = %x[ parted #{parameter} ]
    unless $? == 0
    puts "Fail!! #{output}"
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
  puts "logical: #{logical}"
  (Maxlogical+1 .. logical).each {|dev_num|
    output = %x[lsblk -Pf #{dev}#{dev_num}]
    mountpoint= /MOUNTPOINT=\"(.*)\"/.match(output)
    return mountpoint[1] if not mountpoint[1].empty?
  }
  return false
end

#get free space in device
def get_free(dev)
   output = parted(dev, 'unit', 'mb','print', 'free', '-m')
   unless $? == 0
       return nil;
   end
   fields = output.last.strip.split(':')  # type of last partition
   puts fields.last
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
  output.reverse.each {|i|
    fields = i.strip.split(':')
    if fields.last == 'free'
      # none
    else
      # it is the first non-free partition 

      if fields.first =~ /^\d/
        devnum = fields.first.to_i
      else
        # there is no patition previous to free space
        parted(dev, 'mkpart', 'primary', Default_fs, '1', '100%')
        %x[mkfs.#{Default_fs} #{dev}1 2> /dev/null]
        return true
      end

      if devnum > logical
        logical = devnum
      elsif devnum <= Maxlogical
        primary = devnum
        puts " resize primary on #{dev}: #{primary} <confirm:#{confirm}>"
        confirm = ''
        confirm = 'yes' if is_in_use(dev, logical) # parted ask for confirmation
        puts "primary:"
        output = parted(dev, 'resizepart', primary, confirm, '100%')
        if not output.nil? and logical > 4
          puts " resize logical on #{dev}: #{logical}"
          confirm = ''
          confirm = 'yes' if is_mounted(dev, logical) # parted ask for confirmation
          output = parted(dev,  'resizepart' , logical, confirm, '100%')
          if not output.nil?
            puts "  Resize filesystem: resize2fs #{dev}#{logical}"
            %x[resize2fs #{dev}#{logical}]
          else
            puts "Error2 executing parted. Output was: #{output}"
          end
        elsif output.nil?
          puts "Error1 executing parted. Output was: #{output}"
        end
        return true
      end
    end
  }
end

dv = get_devs()   
#pp dv

dv.each {|d|
   print 
   free = get_free(d)
   if not free                   # New disk!!!
     puts d + " => Format disk know!"
     parted(d, 'mklabel', 'msdos')
     parted(d, 'mkpart', 'primary', default_fs, '1', '100%')
     %x[mkfs.#{Default_fs} #{d}1 2> /dev/null]
   elsif free[/(\d+)/].to_i > 0  # resize!!
     puts d + " => We have FREE space: #{free}"
     resize_disk (d)
   elsif free == '0MB'           # No available space
     puts d + " => Sorry no FREE space for you"
   end
}
