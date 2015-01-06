#!/usr/bin/ruby

require 'vips8'

x = Vips::Image.new 

puts "after first build"
Vips::Object::print_all

x = nil
GC.start
