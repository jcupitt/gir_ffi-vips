#!/usr/bin/ruby

require 'vips8'

Vips::leak_set true

puts "build"
x = Vips::Image.new 
Vips::Object::print_all

puts "free"
x = nil
GC.start
Vips::Object::print_all
