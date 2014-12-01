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

def imageize match_image, value
    return value if match_image == nil
    return value if value.is_a? Vips::Image

    pixel = (Vips::Image.black(1, 1) + value).cast(match_image.format)
    pixel.embed(0, 0, match_image.width, match_image.height, :extend => :copy)
end

class ArrayImageConst < Vips::ArrayImage
    def self.new(value)
        if not value.is_a? Array
            value = [value]
        end

        match_image = value.find {|x| x.is_a? Vips::Image}
        if match_image == nil
            raise Vips::Error, "Argument must contain at least one image."
        end

        value = value.map {|x| imageize match_image, x}

        super(value)
    end
end

# if this gtype needs an array, try to transform the value into one
def arrayize(gtype, value)
    arrayize_map = {
        Vips::array_double_gtype => Vips::ArrayDouble,
        Vips::array_int_gtype => Vips::ArrayInt,
        Vips::array_image_gtype => Vips::ArrayImage
    }

    if arrayize_map.has_key? gtype
        if not value.is_a? Array
            value = [value]
        end

        value = arrayize_map[gtype].new value
    end

    value
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

        # array-ize
        value = arrayize prop.value_type, value

        # enums must be unwrapped, not sure why, they are wrapped 
        # automatically
        puts "name = #{name}, prop = #{prop}"
        if prop.is_a? GObject::ParamSpecEnum
            enum_class = GObject::type_class_ref prop.value_type
            # not sure what to do here
            value = prop.to_native value, 1
        end

        # blob-ize
        if GObject.type_is_a(prop.value_type, Vips::blob_gtype)
            if not value.is_a? Vips::Blob
                value = Vips::Blob.new(nil, value)
            end
        end

        # add imageize, when it's working

        # MODIFY input images need to be copied before assigning them
        if (flags & Vips::ArgumentFlags[:modify]) != 0
            # don't use .copy(): we want to make a new pipeline with no
            # reference back to the old stuff ... this way we can free the
            # previous image earlier 
            new_image = Vips::Image.new_memory
            value.write new_image
            value = new_image
        end

        op.set_property @name, value
    end

    def get_value
        value = @op.property(@name).get_value

        # unblob
        if value.is_a? Vips::Blob
            value = value.get
        end
    end

    def description
        direction = @flags & Vips::ArgumentFlags[:input] != 0 ? 
            "input" : "output"

        result = @name
        result += " " * (15 - @name.length) + " -- " + @prop.get_blurb
        result += ", " + direction 
        result += " " + GObject.type_name(@prop.value_type)
    end

end

# handy for overloads ... want to be able to apply a function to an array, or 
# to a scalar
def smap(x, &block)
    x.is_a?(Array) ? x.map {|x| smap(x, &block)} : block.(x)
end

# we add methods to these below, so we must load first
Vips.load_class :Operation
Vips.load_class :Image

module Vips
    # we also add some stuff directly to Vips::, see VipsExtensions below

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
                @details
            else
                super.to_s
            end
        end
    end

    class Operation
        # fetch arg list, remove boring ones, sort into priority order 
        def get_args
            object_class = GObject.object_class_from_instance self
            io_bits = Vips::ArgumentFlags[:input] | Vips::ArgumentFlags[:output]
            props = object_class.list_properties.select do |prop|
                flags = get_argument_flags prop.name
                flags = Vips::ArgumentFlags.to_native flags, 1
                (flags & io_bits != 0) &&
                    (flags & Vips::ArgumentFlags[:deprecated] == 0)
            end
            args = props.map {|x| Argument.new self, x}
            args.sort! {|a, b| a.priority - b.priority}
        end
    end

    class Image
        def method_missing(name, *args)
            Vips::call_base(name.to_s, self, "", args)
        end

        def self.method_missing(name, *args)
            Vips::call_base name.to_s, nil, "", args
        end

        def self.new_from_file(name, *args)
            filename = Vips.filename_get_filename name
            option_string = Vips.filename_get_options name
            loader = Vips::Foreign::find_load filename
            if loader == nil
                raise Vips::Error
            end

            Vips::call_base loader, nil, option_string, [filename] + args
        end

        def self.new_from_buffer(data, option_string, *args)
            loader = Vips::Foreign::find_load_buffer data
            if loader == nil
                raise Vips::Error
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

        def +(other)
            other.is_a?(Vips::Image) ? add(other) : linear(1, other)
        end

        def -(other)
            other.is_a?(Vips::Image) ? 
                subtract(other) : linear(1, smap(other) {|x| x * -1})
        end

        def *(other)
            other.is_a?(Vips::Image) ? multiply(other) : linear(other, 0)
        end

        def /(other)
            other.is_a?(Vips::Image) ? 
                divide(other) : linear(smap(other) {|x| 1.0 / x}, 0)
        end

        def %(other)
            other.is_a?(Vips::Image) ? 
                remainder(other) : remainder_const(other)
        end

        def **(other)
            other.is_a?(Vips::Image) ? 
                math2(other, :pow) : math2_const(other, :pow)
        end

        def <<(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :lshift) : boolean_const(other, :lshift)
        end

        def >>(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :rshift) : boolean_const(other, :rshift)
        end

        def |(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :or) : boolean_const(other, :or)
        end

        def &(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :and) : boolean_const(other, :and)
        end

        def ^(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :eor) : boolean_const(other, :eor)
        end

        def !
            self ^ -1
        end

        def ~
            self ^ -1
        end

        def +@
            self
        end

        def -@
            self * -1
        end

        def <(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :less) : relational_const(other, :less)
        end

        def <=(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :lesseq) : relational_const(other, :lesseq)
        end

        def >(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :more) : relational_const(other, :more)
        end

        def >(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :moreeq) : relational_const(other, :moreeq)
        end

        def ==(other)
            if other == nil
                false
            elsif other.is_a?(Vips::Image)  
                relational(other, :equal) 
            else
                relational_const(other, :equal)
            end
        end

        def !=(other)
            if other == nil
                true
            elsif other.is_a?(Vips::Image) 
                relational(other, :noteq) 
            else
                relational_const(other, :noteq)
            end
        end

    end

end

# use this module to extend Vips ... we can't do this in the "module Vips"
# block above, for some reason
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
                (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) != 0 
            end

            # do we have a non-nil instance? set the first image arg with this
            if instance != nil
                x = required_input.find do |x|
                    GObject.type_is_a(x.prop.value_type, image_gtype)
                end
                if x == nil
                    raise Vips::Error, 
                        "No #{instance.class} argument to #{name}."
                end
                x.set_value match_image, instance
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
                (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) == 0 
            end

            # make a hash from name to arg
            optional_input = Hash[
                optional_input.map(&:name).zip(optional_input)]

            # find optional unassigned output args
            optional_output = all_args.select do |arg|
                not arg.isset and
                (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) == 0 
            end
            optional_output = Hash[
                optional_output.map(&:name).zip(optional_output)]

            # set all optional args
            log "setting optional values ..."
            optional_values.each do |name, value|
                # we are passed symbols as keys
                name = name.to_s
                log "setting #{name} to #{value}"
                if optional_input.has_key? name
                    log "setting #{name} to #{value}"
                    optional_input[name].set_value match_image, value
                elsif optional_output.has_key? name and value != true
                    raise Vips::Error, 
                        "Optional output argument #{name} must be true."
                elsif not optional_output.has_key? name 
                    raise Vips::Error, "No such option '#{name}',"
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
                    (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                    (arg.flags & Vips::ArgumentFlags[:required]) == 0 
                end
                optional_output = Hash[
                    optional_output.map(&:name).zip(optional_output)]
            end

            # gather output args 
            out = []

            all_args.each do |arg|
                # required output
                if (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                    (arg.flags & Vips::ArgumentFlags[:required]) != 0 
                    out << arg.get_value
                end

                # modified input arg ... this will get the result of the 
                # copy() we did in Argument.set_value above
                if (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                    (arg.flags & Vips::ArgumentFlags[:modify]) != 0 
                    out << arg.get_value
                end
            end

            out_dict = {}
            optional_values.each do |name, value|
                # we are passed symbols as keys
                name = name.to_s
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
