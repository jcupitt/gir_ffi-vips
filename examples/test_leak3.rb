#!/usr/bin/ruby 

require 'gir_ffi'

require 'tracer'

Tracer.add_filter do |event, file, line, id, binding, klass, *rest|
      "file" =~ /gir/
end

GirFFI.setup :Vips

Vips::init($PROGRAM_NAME)

puts ""
puts "** creating operation:"
op = Vips::Operation.new "jpegload"
op.set_property "filename", "/data/john/pics/k2.jpg"
Vips::Object::print_all

puts ""
puts "** building operation:"
op.build
Vips::Object::print_all

puts ""
puts "** fetching output image"
Tracer::on
out = op.property("out").get_value
Tracer::off
Vips::Object::print_all

puts ""
puts "** unreffing output objects"
op.unref_outputs
Vips::Object::print_all

puts ""
puts "** freeing operation"
op = nil
GC.start
Vips::Object::print_all

puts ""
puts "** freeing image"
out = nil
GC.start
Vips::Object::print_all

puts ""
puts "** done"

