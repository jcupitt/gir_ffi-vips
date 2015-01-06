#!/usr/bin/ruby 

require 'gir_ffi'

GirFFI.setup :Vips
Vips::init($PROGRAM_NAME)
Vips::cache_set_max 0
op = Vips::Operation.new "jpegload"
op.set_property "filename", "/data/john/pics/k2.jpg"
puts "** objects before build:"
Vips::Object::print_all

op2 = Vips::cache_operation_build op
puts "** objects after build:"
Vips::Object::print_all

GObject::Lib.g_object_unref op
op = nil

out = op2.property("out").get_value

op2.unref_outputs

op2 = nil
GC.start

puts "** objects after running operation:"
Vips::Object::print_all

out = nil
GC.start

puts "** objects after tidy up:"
Vips::Object::print_all

