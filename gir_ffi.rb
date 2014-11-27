#!/usr/bin/ruby

# gem install gir_ffi

require 'gir_ffi'

GirFFI.setup :Vips

Vips::init $0

if ARGV.length < 2
    puts "usage: #{$0}: input-filename output-filename"
    exit 1
end

# load file

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

object_class = GObject.object_class_from_instance op
props = object_class.list_properties

puts "op has properties:"
props.each do |x| 
    flags = op.get_argument_flags x.name
    flags = Vips::ArgumentFlags.to_native(flags, 1)

    isset = op.argument_isset x.name
    desc = ""
    [:required, :input, :output, :deprecated].each do |name|
        bits = Vips::ArgumentFlags.to_native(name, 1).to_i
        if flags & bits != 0
            desc += name.to_s + " "
        end
    end
    # to go the other way:
    # Vips::ArgumentFlags.from_native 2, 2

    puts "  #{x.name} -- #{desc}, #{x.get_nick}, #{x.get_blurb}"
end

puts "building ..."
op2 = Vips::cache_operation_build op
if op2 == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

puts "fetching output ..."
image = op2.property("out").get_value

puts "unreffing operation"
op2.unref_outputs()

puts "image.width = #{image.property("width").get_value}"

# run an operation

op = Vips::Operation::new "invert"
if op == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

op.set_property "in", image

op2 = Vips::cache_operation_build op
if op2 == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

image = op2.property("out").get_value

# save file

name = ARGV[1]

filename = Vips::filename_get_filename name
option_string = Vips::filename_get_options name

saver = Vips::Foreign::find_save filename
if saver == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

puts "selected saver #{saver}"

op = Vips::Operation::new saver
if op == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

if op.set_from_string(option_string) != 0
    puts "#{Vips::error_buffer}"
    exit 1
end

op.set_property "in", image
op.set_property "filename", filename

puts "building ..."
op2 = Vips::cache_operation_build op
if op2 == nil
    puts "#{Vips::error_buffer}"
    exit 1
end

puts "unreffing operation"
op2.unref_outputs()

