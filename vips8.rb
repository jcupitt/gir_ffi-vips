#!/usr/bin/ruby

# gem install gir_ffi

# see this to see how to define overrides
# https://github.com/mvz/gir_ffi-gtk/blob/master/lib/gir_ffi-gtk/base.rb

require 'gir_ffi'

GirFFI.setup :Vips

module Vips
    # automatically grab the vips error buffer, if no message is supplied
    class Error < RuntimeError
        def initialize(msg = nil)
            if msg
                @details = msg
            elsif Vips::error_buffer() != ""
                @details = Vips.error_buffer()
                Vips.error_clear()
            else 
                @details = nil
            end
        end

        def to_s
            if @details != nil
                result = @details
            else
                result = super.to_s
            end
            result
        end
    end

end

if Vips::init($PROGRAM_NAME) != 0 
    raise Vips::Error
end
