#!/usr/bin/ruby 

require 'gir_ffi'

GirFFI.setup :Vips

Vips::init($PROGRAM_NAME)

op = Vips::Operation.new "jpegload"
op.set_property "filename", "/home/john/pics/k2.jpg"
op.build
puts ""
puts "** after _build()"
Vips::Object::print_all

puts ""
puts "** fetching object GValue "
out = op.property("out")
Vips::Object::print_all

puts ""
puts "** waiting ..."
gets

puts ""
puts "** finalizing GValue ... object count should fall again"
out = nil
GC.start
Vips::Object::print_all

puts ""
puts "** waiting ..."
gets

