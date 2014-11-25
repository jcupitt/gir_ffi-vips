#!/usr/bin/ruby

# gem install gir_ffi

require 'gir_ffi'

GirFFI.setup :Vips

Vips::init $0

if ARGV.length < 1
    puts "usage: #{$0}: filename ..."
    exit 1
end

name = ARGV[0]
puts "loading file #{name}"

filename = Vips::filename_get_filename name
option_string = Vips::filename_get_options name

loader = Vips::Foreign::find_load filename
if loader == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

puts "selected loader #{loader}"

op = Vips::Operation::new loader
if op == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

if op.set_from_string(option_string) != 0
    puts "#{Vips::error_buffer}"
    exit 1
end

op.set_property "filename", filename

puts "building ..."
op2 = Vips::cache_operation_build op
if op2 == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

puts "fetching output ..."
out = op2.property("out").get_value

puts "unreffing operation"
op2.unref_outputs()

puts "image width = #{out.property("width").get_value}"
