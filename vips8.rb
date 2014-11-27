#!/usr/bin/ruby

# gem install gir_ffi

# see this to see how to define overrides
# https://github.com/mvz/gir_ffi-gtk/blob/master/lib/gir_ffi-gtk/base.rb

require 'gir_ffi'

GirFFI.setup :Vips

if Vips::init($PROGRAM_NAME) != 0 
    raise RuntimeError, 'unable to start vips, #{Vips.error_buffer}'
end

class Argument
    attr_reader :op, :prop, :name, :flags, :priority, :isset

    def initialize(op, prop)
        @op = op
        @prop = prop
        @name = prop.name
        @flags = op.get_argument_flags @name
        # we need a bit pattern, not a symbolic name
        @flags = Vips::ArgumentFlags.to_native @flags, 1
        @priority = op.get_argument_priority @name
        @isset = op.argument_isset @name
    end

    def set_value(match_image, value)
        # insert some boxing code
        op.set_property @name, value
    end

    def get_value
        # insert some unboxing code
        @op.property(@name).get_value
    end

    def description
        input_bits = Vips::ArgumentFlags.to_native(:input, 1).to_i
        if @flags & input_bits != 0 
            direction = "input"
        else 
            direction = "output"
        end

        result = @name
        result += " " * (15 - @name.length) + " -- " + @prop.get_blurb
        result += ", " + direction 
        result += " " + GObject.type_name(@prop.value_type)
    end

end

# we add methods to these below, so we must load first
Vips.load_class :Operation
Vips.load_class :Image

module Vips
    # automatically grab the vips error buffer, if no message is supplied
    class Error < RuntimeError
        def initialize(msg = nil)
            if msg
                @details = msg
            elsif Vips::error_buffer != ""
                @details = Vips.error_buffer
                Vips.error_clear
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

    class Operation
        # fetch arg list, remove boring ones, sort into priority order 
        def get_args
            object_class = GObject.object_class_from_instance self
            props = object_class.list_properties
            deprecated_bits = Vips::ArgumentFlags.to_native(:deprecated, 1).to_i
            io_bits = Vips::ArgumentFlags.to_native(:input, 1).to_i
            io_bits |= Vips::ArgumentFlags.to_native(:output, 1).to_i
            args = []
            props.each do |prop|
                flags = get_argument_flags prop.name
                flags = Vips::ArgumentFlags.to_native flags, 1
                if (flags & io_bits == 0) || (flags & deprecated_bits != 0)
                    next
                end

                args << Argument.new(self, prop)
            end
            args.sort! {|a, b| a.priority - b.priority}
        end
    end

    class Image
        def method_missing(name, *args)
            puts "in Vips.Image.#{name}"
            puts "args are:"
            args.each {|x| puts "   #{x}"}
        end

    end
end

# use this module to extend Vips
module VipsExtensions
    def self.included base
        base.extend ClassMethods
    end

    module ClassMethods
        # need the gtypes for various vips types
        @@array_int_gtype = GObject.type_from_name "VipsArrayInt"
        def array_int_gtype 
            @@array_int_gtype
        end

        #array_int_gtype = GObject.type_from_name "VipsArrayInt"
        array_double_gtype = GObject.type_from_name "VipsArrayDouble"
        array_image_gtype = GObject.type_from_name "VipsArrayImage"
        blob_gtype = GObject.type_from_name "VipsBlob"
        image_gtype = GObject.type_from_name "VipsImage"
        operation_gtype = GObject.type_from_name "VipsOperation"

        def call(name, *args)
            op = Vips::Operation.new name

            puts "in Vips.call"
            puts "args are:"
            args.each {|x| puts "   #{x}"}
        end
    end
end

module Vips
    include VipsExtensions
end
