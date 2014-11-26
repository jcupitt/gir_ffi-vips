#!/usr/bin/ruby

require './vips8'

#raise Vips::Error.new('a'), 'b'
raise Vips::Error, 'b'

op = Vips::Operation::new ARGV[0]
if op == nil
    raise Vips::Error, 'unable to make operation'
end


