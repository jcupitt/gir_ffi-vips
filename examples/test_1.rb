#!/usr/bin/ruby

puts "starting ... "

require 'gir_ffi'

GirFFI.setup :Vips

op_name = "cast"
puts "building operation #{op_name} ... "
op = Vips::Operation::new op_name
if op == nil
    raise Vips::Error, 'unable to make operation'
end


