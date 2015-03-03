# This module provides a set of overrides for the vips image processing library
# used via the gir_ffi gem. 
#
# Author::    John Cupitt  (mailto:jcupitt@gmail.com)
# License::   MIT

require 'gir_ffi'

GirFFI.setup :Vips

if Vips::init($PROGRAM_NAME) != 0 
    raise RuntimeError, "unable to start vips, #{Vips::error_buffer}"
end

at_exit {
    Vips::shutdown
}

# about as crude as you could get
#$vips_debug = true
$vips_debug = false

def log str # :nodoc:
    if $vips_debug
        puts str
    end
end

if $vips_debug
    log "Vips::leak_set(true)"
    Vips::leak_set(true) 
end

# we add methods to these below, so we must load first
Vips::load_class :Operation
Vips::load_class :Image

require 'vips8/error'
require 'vips8/argument'
require 'vips8/operation'
require 'vips8/call'
require 'vips8/image'
require 'vips8/methods'
