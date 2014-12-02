#!/usr/bin/ruby

puts "starting ... "

require 'ruby-vips8'

op_name = "black"
puts "building operation #{op_name} ... "
op = Vips::Operation.new op_name
if op == nil
    raise Vips::Error, 'unable to make operation'
end

puts "fetching args ... "
op.get_args.each do |arg|
    puts "#{arg.description}"
end

im = Vips::call "black", 100, 100, :bands => 12

im = Vips::Image.black 100, 100, :bands => 12

im2 = im.add im

im = Vips::Image.new_from_file ARGV[0], :fail => true
im.write_to_file "x.jpg"

im = Vips::Image.new_from_array [1, 2, 3]

im = Vips::Image.new_from_array [[4, 5], [6, 7]], 8, 9

im += im2

im += 4

im += [1,2,3,4,5,6,7,8,9,10,11,12]
im.write_to_file "x.v"



