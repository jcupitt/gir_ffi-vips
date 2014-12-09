#!/usr/bin/ruby

require 'vips8'

x = Vips::Image.new 

puts "after first build"
Vips::Object::print_all

x = nil

GC.enable 
GC.start
GC.start

puts "after GC but before exit"
Vips::Object::print_all
