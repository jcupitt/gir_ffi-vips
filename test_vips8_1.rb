#!/usr/bin/ruby

puts "starting ... "

require './vips8'

puts "building operation ... "
op = Vips::Operation::new ARGV[0]
if op == nil
    raise Vips::Error, 'unable to make operation'
end

puts "fetching args ... "
op.get_args.each do |arg|
    puts "#{arg.description}"
end

result = Vips.call "black", 100, 100, :bands => 12




