#!/usr/bin/ruby 

require 'gir_ffi'

GirFFI.setup :Vips

Vips::init($PROGRAM_NAME)

op = Vips::Operation.new "jpegload"
op.set_property "filename", ARGV[0]

# we should have a single object with a single ref, the jpegload operation
puts ""
puts "** objects before build:"
Vips::Object::print_all

result = op.build
if result != 0
    puts "build failed: #{Vips::error_buffer}"
    exit
end

# building a jpeg loader creates a VipsImage in the "out" property with a
# single ref ... this output object holds a ref back to the operation that 
# created it, ie. unreffing "out" will in turn drop a ref to "op"

# we get 
# @out, count=1, floating ref, unreffing this will also drop a ref from @op
# @op, count=2, once ref held by Ruby, one ref held by @out

puts ""
puts "** objects after build:"
Vips::Object::print_all

# fetch constructed image ... we need to take over the floating ref, ie.
# (transfer full), but I think we actually make a new one, ie. gir_ffi is doing
# (transfer none)
out = op.property("out").get_value

op = nil
GC.start

puts ""
puts "** objects after running operation:"
Vips::Object::print_all

out = nil
GC.start

puts ""
puts "** objects after tidy up:"
Vips::Object::print_all

