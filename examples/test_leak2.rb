#!/usr/bin/ruby 

require 'vips8'

Vips::cache_set_max 0

if ARGV.length < 1
    raise "usage: #{$PROGRAM_NAME}: input-file"
end

im = Vips::Image.new_from_file ARGV[0]

im = nil
GC.start
