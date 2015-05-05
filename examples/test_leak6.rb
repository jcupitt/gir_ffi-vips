#!/usr/bin/ruby 

require 'vips8'
Vips::leak_set true

puts "creating ArrayDouble ..."
x = Vips::ArrayDouble.new [1, 2, 3]
Vips::Object::print_all

puts "freeing ArrayDouble ..."
x = nil
GC.start
Vips::Object::print_all

puts "exiting ..."
