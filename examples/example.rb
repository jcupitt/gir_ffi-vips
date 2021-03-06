#!/usr/bin/ruby 

require 'vips8'

#Vips::cache_set_max 0
Vips::leak_set true

if ARGV.length < 2
    raise "usage: #{$PROGRAM_NAME}: input-file output-file"
end

1.times do |i|
    puts "loop #{i}"

    # we don't need random access to this image, we will just process 
    # top to bottom
    im = Vips::Image.new_from_file ARGV[0], :access => :sequential

    # multiply the green channel by 2
    im *= [1, 2, 1]

    # make a convolution mask
    mask = Vips::Image.new_from_array [
            [-1, -1, -1],
            [-1, 16, -1],
            [-1, -1, -1]], 8

    # convolve the image with the mask
    im = im.conv mask

    # write back to the filesystem
    im.write_to_file ARGV[1]

end

im = nil
mask = nil
GC.start
