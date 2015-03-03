#!/usr/bin/ruby 

require 'vips8'

#$vips_debug = true

Vips::cache_set_max 0

if ARGV.length != 1
    raise "usage: #{$PROGRAM_NAME}: input-file"
end

# we don't need random access to this image, we will just process 
# top to bottom
im = Vips::Image.new_from_file ARGV[0]
puts ""
puts "** after new_from_file"
GC.start
Vips::Object::print_all
im.write_to_file("x.v")
gets

puts ""
puts "** after unref of image"
im = nil
GC.start
Vips::Object::print_all
gets

puts ""
puts "** all done"
gets
