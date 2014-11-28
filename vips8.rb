#!/usr/bin/ruby

# gem install gir_ffi

# see this to see how to define overrides
# https://github.com/mvz/gir_ffi-gtk/blob/master/lib/gir_ffi-gtk/base.rb
#
# a = Vips::Image.new
# irb(main):026:0> a.type_class.g_type_class.g_type
# => 39913376
# irb(main):002:0> Vips.image_gtype
# => 39913376

require 'gir_ffi'

GirFFI.setup :Vips

if Vips::init($PROGRAM_NAME) != 0 
    raise RuntimeError, "unable to start vips, #{Vips.error_buffer}"
end

# about as crude as you could get
$debug = true

def log str
    if $debug
        puts str
    end
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
        if @flags & Vips::argument_bits[:input] != 0 
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
            io_bits = Vips::argument_bits[:input] | Vips::argument_bits[:output]
            args = []
            props.each do |prop|
                flags = get_argument_flags prop.name
                flags = Vips::ArgumentFlags.to_native flags, 1
                if (flags & io_bits == 0) || 
                    (flags & Vips::argument_bits[:deprecated] != 0)
                    next
                end

                args << Argument.new(self, prop)
            end
            args.sort! {|a, b| a.priority - b.priority}
        end
    end

    class Image
        def method_missing(name, *args)
            Vips::call_base(name.to_s, self, "", args)
        end

        def self.new_from_file(name, *args)
            filename = Vips.filename_get_filename name
            option_string = Vips.filename_get_options name
            loader = Vips::Foreign::find_load filename
            if loader == nil
                raise Vips::Error, "No known loader for '#{filename}'."
            end

            Vips::call_base loader, nil, option_string, [filename] + args
        end

        def self.new_from_buffer(data, option_string, *args)
            loader = Vips::Foreign::find_load_buffer data
            if loader == nil
                raise Vips::Error, "No known loader for buffer."
            end

            Vips::call_base loader, nil, option_string, [data] + args
        end

        def self.new_from_array(array, scale = 1, offset = 0)
            # we accept a 1D array and assume height == 1, or a 2D array
            # and check all lines are the same length
            if not array.is_a? Array
                raise Vips::Error, "Argument is not an array."
            end

            if array[0].is_a? Array
                height = array.length
                width = array[0].length
                if not array.all? {|x| x.is_a? Array}
                    raise Vips::Error, "Not a 2D array."
                end
                if not array.all? {|x| x.length == width}
                    raise Vips::Error, "Array not rectangular."
                end
                array = array.flatten
            else
                height = 1
                width = array.length
            end

            if not array.all? {|x| x.is_a? Numeric}
                raise Vips::Error, "Not all array elements are Numeric."
            end

            image = Vips::Image::new_matrix_from_array width, height, array

            # be careful to set them as double
            image.set_double 'scale', scale.to_f
            image.set_double 'offset', offset.to_f

            return image
        end

        def write_to_file(name, *args)
            filename = Vips.filename_get_filename name
            option_string = Vips.filename_get_options name
            saver = Vips::Foreign::find_save filename
            if saver == nil
                raise Vips::Error, "No known saver for '#{filename}'."
            end

            Vips::call_base saver, self, option_string, [filename] + args
        end

        def write_to_buffer(format_string, *args)
            filename = Vips.filename_get_filename format_string
            option_string = Vips.filename_get_options format_string
            saver = Vips::Foreign::find_save_buffer filename
            if saver == nil
                raise Vips::Error, "No known saver for '#{filename}'."
            end

            Vips::call_base saver, self, option_string, args
        end

        def +(other, *args)
            log "in + operator overload"

            if other.is_a? Vips::Image
                add(other)
            else
                linear(1, other)
            end
        end

    end

end

# use this module to extend Vips
module VipsExtensions
    def self.included base
        base.extend VipsClassMethods
    end

    module VipsClassMethods
        # need the gtypes for various vips types
        @@array_int_gtype = GObject.type_from_name "VipsArrayInt"
        def array_int_gtype 
            @@array_int_gtype
        end

        @@array_double_gtype = GObject.type_from_name "VipsArrayDouble"
        def array_double_gtype 
            @@array_double_gtype
        end

        @@array_image_gtype = GObject.type_from_name "VipsArrayImage"
        def array_image_gtype 
            @@array_image_gtype
        end

        @@blob_gtype = GObject.type_from_name "VipsBlob"
        def blob_gtype 
            @@blob_gtype
        end

        @@image_gtype = GObject.type_from_name "VipsImage"
        def image_gtype 
            @@image_gtype
        end

        @@operation_gtype = GObject.type_from_name "VipsOperation"
        def operation_gtype 
            @@operation_gtype
        end

        # masks for ArgumentFlags
        bits = {}
        [:required, :input, :output, :deprecated, :modify].each do |name|
            bits[name] = Vips::ArgumentFlags.to_native(name, 1).to_i
        end
        @@argument_bits = bits
        def argument_bits 
            @@argument_bits
        end

        # internal call entry ... see Vips::call for the public entry point
        def call_base(name, instance, option_string, supplied_values)
            log "in Vips.call_base"
            log "name = #{name}"
            log "instance = #{instance}"
            log "option_string = #{option_string}"
            log "supplied_values are:"
            supplied_values.each {|x| log "   #{x}"}

            if supplied_values.last.is_a? Hash
                optional_values = supplied_values.last
                supplied_values.delete_at -1
            else
                optional_values = {}
            end

            op = Vips::Operation.new name
            if op == nil
                raise Vips::Error
            end

            # set string options first 
            if option_string
                if op.set_from_string(option_string) != 0
                    raise Error
                end
            end

            all_args = op.get_args

            # the instance, if supplied, must be a vips image ... we use it for
            # match_image, below
            if instance and not instance.is_a? Vips::Image
                raise Vips::Error, "@instance is not a Vips::Image."
            end

            # if the op needs images but the user supplies constants, we expand
            # them to match the first input image argument ... find the first
            # image
            match_image = instance
            if match_image == nil
                match_image = supplied_values.find {|x| x.is_a? Vips::Image}
            end
            if match_image == nil
                match = optional_values.find do |name, value|
                    value.is_a? Vips::Image
                end
                # if we found a match, it'll be [name, value]
                if match
                    match_image = match[1]
                end
            end

            # find unassigned required input args
            required_input = all_args.select do |arg|
                not arg.isset and
                (arg.flags & Vips.argument_bits[:input]) != 0 and
                (arg.flags & Vips.argument_bits[:required]) != 0 
            end

            # do we have a non-nil instance? set the first image arg with this
            if instance != nil
                x = required_input.find do |x|
                    GObject.type_is_a(x.prop.value_type, image_gtype)
                end
                if x
                    x.set_value match_image, instance
                else
                    raise Vips::Error, 
                        "No #{instance.class} argument to #{name}."
                end
                required_input.delete x
            end

            if required_input.length != supplied_values.length
                raise Vips::Error, 
                    "Wrong number of arguments. '#{name}' requires " +
                    "#{required_input.length} arguments, you supplied " +
                    "#{supplied_values.length}."
            end

            required_input.zip(supplied_values).each do |arg, value|
                arg.set_value match_image, value
            end

            # find optional unassigned input args
            optional_input = all_args.select do |arg|
                not arg.isset and
                (arg.flags & Vips.argument_bits[:input]) != 0 and
                (arg.flags & Vips.argument_bits[:required]) == 0 
            end

            # make a hash from name to arg
            optional_input = Hash.new 
                optional_input.map(&:name).zip(optional_input)

            # find optional unassigned output args
            optional_output = all_args.select do |arg|
                not arg.isset and
                (arg.flags & Vips.argument_bits[:output]) != 0 and
                (arg.flags & Vips.argument_bits[:required]) == 0 
            end
            optional_output = Hash.new 
                optional_output.map(&:name).zip(optional_output)

            # set all optional args
            optional_values.each do |name, value|
                if optional_input.has_key? name
                    optional_input[name].set_value match_image, value
                elsif optional_output.has_key? name and value != true
                    raise Vips::Error, 
                        "Optional output argument #{name} must be true."
                end
            end

            # call
            op2 = Vips.cache_operation_build op
            if op2 == nil
                raise Vips::Error
            end

            # rescan args if op2 is different from op
            if op2 != op
                all_args = op2.get_args()

                # find optional unassigned output args
                optional_output = all_args.select do |arg|
                    not arg.isset and
                    (arg.flags & Vips.argument_bits[:output]) != 0 and
                    (arg.flags & Vips.argument_bits[:required]) == 0 
                end
                optional_output = Hash.new 
                    optional_output.map(&:name).zip(optional_output)
            end

            # gather output args 
            out = []

            all_args.each do |arg|
                # required output
                if (arg.flags & Vips.argument_bits[:output]) != 0 and
                    (arg.flags & Vips.argument_bits[:required]) != 0 
                    out << arg.get_value
                end

                # modified input arg ... this will get the result of the 
                # copy() we did in Argument.set_value above
                if (arg.flags & Vips.argument_bits[:input]) != 0 and
                    (arg.flags & Vips.argument_bits[:modify]) != 0 
                    out << arg.get_value
                end
            end

            out_dict = {}
            optional_values.each do |name, value|
                if optional_output.has_key? name
                    out_dict[name] = optional_output[name].get_value
                end
            end
            if out_dict != {}
                out << out_dict
            end

            if out.length == 1
                out = out[0]
            elsif out.length == 0
                out = nil
            end

            # unref everything now we have refs to all outputs we want
            op2.unref_outputs

            log "success! #{name}.out = #{out}"

            return out
        end

        # user entry point ... run any vips operation
        def call(name, *args)
            call_base name, nil, "", args
        end
    end
end

module Vips
    include VipsExtensions
end
