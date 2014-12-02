#!/usr/bin/ruby

puts "starting ... "

require './vips8'

array = [1] * 10

blb = Vips::Blob.new(nil, array)
