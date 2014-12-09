require 'gir_ffi'

GirFFI.setup :Vips

if Vips::init($PROGRAM_NAME) != 0 
    raise RuntimeError, "unable to start vips, #{Vips::error_buffer}"
end

at_exit {
    Vips::shutdown
}

require 'vips8/vips8'
