# This module provides a set of overrides for the vips image processing library
# used via the gir_ffi gem. 
#
# Author::    John Cupitt  (mailto:jcupitt@gmail.com)
# License::   MIT

# about as crude as you could get
$vips_debug = true
#$vips_debug = false

def log str # :nodoc:
    if $vips_debug
        puts str
    end
end

if $vips_debug
    log "Vips::leak_set(true)"
    Vips::leak_set(true) 
end

# This class is used internally to convert Ruby values to arguments to libvips
# operations. 
class Argument # :nodoc:
    attr_reader :op, :prop, :name, :flags, :priority, :isset

    def initialize(op, prop)
        @op = op
        @prop = prop
        @name = prop.name.tr '-', '_'
        @flags = op.get_argument_flags @name
        # we need a bit pattern, not a symbolic name
        @flags = Vips::ArgumentFlags.to_native @flags, 1
        @priority = op.get_argument_priority @name
        @isset = op.argument_isset @name
    end

    private

    def self.imageize match_image, value
        return value if match_image == nil
        return value if value.is_a? Vips::Image

        pixel = (Vips::Image.black(1, 1) + value).cast(match_image.format)
        pixel.embed(0, 0, match_image.width, match_image.height, 
                    :extend => :copy)
    end

    class ArrayImageConst < Vips::ArrayImage # :nodoc: 
        def self.new(value)
            if not value.is_a? Array
                value = [value]
            end

            match_image = value.find {|x| x.is_a? Vips::Image}
            if match_image == nil
                raise Vips::Error, "Argument must contain at least one image."
            end

            value = value.map {|x| Argument::imageize match_image, x}

            super(value)
        end
    end

    # if this gtype needs an array, try to transform the value into one
    def self.arrayize(gtype, value)
        arrayize_map = {
            Vips::TYPE_ARRAY_DOUBLE => Vips::ArrayDouble,
            Vips::TYPE_ARRAY_INT => Vips::ArrayInt,
            Vips::TYPE_ARRAY_IMAGE => ArrayImageConst
        }

        if arrayize_map.has_key? gtype
            if not value.is_a? Array
                value = [value]
            end

            value = arrayize_map[gtype].new value
        end

        value
    end

    def self.unwrap value
        [Vips::Blob, Vips::ArrayDouble, Vips::ArrayImage, 
            Vips::ArrayInt].each do |cls|
            if value.is_a? cls
                value = value.get
                break 
            end
        end

        # we could try to unpack GirFFI::SizedArray with to_a, but that's not
        # the right thing to do for blobs like profiles

        value
    end

    public

    def set_value(match_image, value)
        # array-ize
        value = Argument::arrayize prop.value_type, value

        # blob-ize
        if GObject::type_is_a(prop.value_type, Vips::TYPE_BLOB)
            if not value.is_a? Vips::Blob
                value = Vips::Blob.new(nil, value)
            end
        end

        # image-ize
        if GObject::type_is_a(prop.value_type, Vips::TYPE_IMAGE)
            if not value.is_a? Vips::Image
                value = imageize match_image, value
            end
        end

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
        Argument::unwrap(@op.property(@name).get_value)
    end

    def description
        name = @name
        blurb = @prop.get_blurb
        direction = @flags & Vips::ArgumentFlags[:input] != 0 ? 
            "input" : "output"
        type = GObject::type_name(@prop.value_type)

        result = "[#{name}] #{blurb}, #{direction} #{type}"
    end

end

# we add methods to these below, so we must load first
Vips::load_class :Operation
Vips::load_class :Image

# This module provides a set of overrides for the {vips image processing 
# library}[http://www.vips.ecs.soton.ac.uk]
# used via the {gir_ffi gem}[https://rubygems.org/gems/gir_ffi]. 
#
# It needs vips-7.42 or later to be installed, 
# and <tt>Vips-8.0.typelib</tt>, the vips typelib, needs to be on your 
# +GI_TYPELIB_PATH+.
#
# == Example
#
#    require 'vips8'
#
#    if ARGV.length < 2
#        raise "usage: #{$PROGRAM_NAME}: input-file output-file"
#    end
#
#    im = Vips::Image.new_from_file ARGV[0], :access => :sequential
#
#    im *= [1, 2, 1]
#
#    mask = Vips::Image.new_from_array [
#            [-1, -1, -1],
#            [-1, 16, -1],
#            [-1, -1, -1]], 8
#    im = im.conv mask
#
#    im.write_to_file ARGV[1]
#
# This example loads a file, boosts the green channel (I'm not sure why), 
# sharpens the image, and saves it back to disc again. 
#
# Vips::Image.new_from_file can load any image file supported by vips. In this
# example, we will be accessing pixels top-to-bottom as we sweep through the
# image reading and writing, so :sequential access mode is best for us. The
# default mode is :random, this allows for full random access to image pixels,
# but is slower and needs more memory. See the libvips API docs for VipsAccess
# for full details
# on the various modes available. You can also load formatted images from 
# memory buffers or create images that wrap C-style memory arrays. 
#
# Multiplying the image by an array constant uses one array element for each
# image band. This line assumes that the input image has three bands and will
# double the middle band. For RGB images, that's doubling green.
#
# Vips::Image.new_from_array creates an image from an array constant. The 8 at
# the end sets the scale: the amount to divide the image by after 
# integer convolution. See the libvips API docs for vips_conv() (the operation
# invoked by Vips::Image.conv) for details. 
#
# Vips::Image.write_to_file writes an image back to the filesystem. It can write
# any format supported by vips: the file type is set from the filename suffix.
# You can also write formatted images to memory buffers, or dump image data to a
# raw memory array. 
#
# == How it works
#
# The C sources to libvips include a set of specially formatted
# comments which describe its interfaces. When you compile the library,
# gobject-introspection generates <tt>Vips-8.0.typelib</tt>, a file 
# describing how to use libvips.
#
# gir_ffi loads this typelib and uses it to let you call functions in libvips
# directly from Ruby. However, the interface you get from raw gir_ffi is 
# rather ugly, so ruby-vips8 adds a set of overrides which try to make it 
# nicer to use. 
#
# The API you end up with is a Ruby-ish version of the C API. Full documentation
# on the operations and what they do is there, you can use it directly. This
# document explains the features of the Ruby API and lists the available libvips
# operations very briefly. 
#
# == Automatic wrapping
#
# ruby-vips8 adds a Vips::Image.method_missing handler to Vips::Image and uses
# it to look up vips operations. For example, the libvips operation +add+, which
# appears in C as vips_add(), appears in Ruby as Vips::image.add. 
#
# The operation's list of required arguments is searched and the first input 
# image is set to the value of +self+. Operations which do not take an input 
# image, such as Vips::Image.black, appear as class methods. The remainder of
# the arguments you supply in the function call are used to set the other
# required input arguments. If the final supplied argument is a hash, it is used
# to set any optional input arguments. The result is the required output 
# argument if there is only one result, or an array of values if the operation
# produces several results. 
#
# For example, Vips::image.min, the vips operation that searches an image for 
# the minimum value, has a large number of optional arguments. You can use it to
# find the minimum value like this:
#
#   min_value = image.min
#
# You can ask it to return the position of the minimum with :x and :y.
#   
#   min_value, x_pos, y_pos = image.min :x => true, :y => true
#
# Now x_pos and y_pos will have the coordinates of the minimum value. There's
# actually a convenience function for this, Vips::Image.minpos.
#
# You can also ask for the top n minimum, for example:
#
#   min_value, x_pos, y_pos = image.min :size => 10,
#       :x_array => true, :y_array => true
#
# Now x_pos and y_pos will be 10-element arrays. 
#
# Because operations are member functions and return the result image, you can
# chain them. For example, you can write:
#
#   result_image = image.imag.cos
#
# to calculate the cosing of the imaginary part of a complex image. 
# There are also a full set
# of arithmetic operator overloads, see below.
#
# libvips types are also automatically wrapped. The override looks at the type 
# of argument required by the operation and converts the value you supply, 
# when it can. For example, "linear" takes a Vips::ArrayDouble as an argument 
# for the set of constants to use for multiplication. You can supply this 
# value as an integer, a float, or some kind of compound object and it 
# will be converted for you. You can write:
#
#   result_image = image.linear 1, 3 
#   result_image = image.linear 12.4, 13.9 
#   result_image = image.linear [1, 2, 3], [4, 5, 6] 
#   result_image = image.linear 1, [4, 5, 6] 
#
# And so on. A set of overloads are defined for Vips::Image.linear, see below.
#
# It does a couple of more ambitious conversions. It will automatically convert
# to and from the various vips types, like Vips::Blob and Vips::ArrayImage. For
# example, you can read the ICC profile out of an image like this: 
#
#   profile = im.get_value "icc-profile-data"
#
# and profile will be a byte array.
#
# If an operation takes several input images, you can use a constant for all but
# one of them and the wrapper will expand the constant to an image for you. For
# example, Vips::Image.ifthenelse uses a condition image to pick pixels 
# between a then and an else image:
#
#   result_image = condition_image.ifthenelse then_image, else_image
#
# You can use a constant instead of either the then or the else parts and it
# will be expanded to an image for you. If you use a constant for both then and
# else, it will be expanded to match the condition image. For example:
#
#    result_image = condition_image.ifthenelse [0, 255, 0], [255, 0, 0]
#
# Will make an image where true pixels are green and false pixels are red.
#
# This is useful for Vips::Image.bandjoin, the thing to join two or more 
# images up bandwise. You can write:
#
#   rgba = rgb.bandjoin 255
#
# to add a constant 255 band to an image, perhaps to add an alpha channel. Of
# course you can also write:
#
#   result_image = image1.bandjoin image2
#   result_image = image1.bandjoin [image2, image3]
#   result_image = Vips::Image.bandjoin [image1, image2, image3]
#   result_image = image1.bandjoin [image2, 255]
#
# and so on. 
# 
# == Automatic rdoc documentation
#
# These API docs are generated automatically by Vips::generate_rdoc. It examines
# libvips and writes a summary of each operation and the arguments and options
# that operation expects. 
# 
# Use the C API docs for more detail.
#
# == Exceptions
#
# The wrapper spots errors from vips operations and raises the Vips::Error
# exception. You can catch it in the usual way. 
# 
# == Draw operations
#
# Paint operations like Vips::Image.draw_circle and Vips::Image.draw_line 
# modify their input image. This
# makes them hard to use with the rest of libvips: you need to be very careful
# about the order in which operations execute or you can get nasty crashes.
#
# The wrapper spots operations of this type and makes a private copy of the
# image in memory before calling the operation. This stops crashes, but it does
# make it inefficient. If you draw 100 lines on an image, for example, you'll
# copy the image 100 times. The wrapper does make sure that memory is recycled
# where possible, so you won't have 100 copies in memory. 
#
# If you want to avoid the copies, you'll need to call drawing operations
# yourself.
#
# == Overloads
#
# The wrapper defines the usual set of arithmetic, boolean and relational
# overloads on image. You can mix images, constants and lists of constants
# (almost) freely. For example, you can write:
#
#   result_image = ((image * [1, 2, 3]).abs < 128) | 4
#
# == Expansions
#
# Some vips operators take an enum to select an action, for example 
# Vips::Image.math can be used to calculate sine of every pixel like this:
#
#   result_image = image.math :sin
#
# This is annoying, so the wrapper expands all these enums into separate members
# named after the enum. So you can write:
#
#   result_image = image.sin
#
# == Convenience functions
#
# The wrapper defines a few extra useful utility functions: 
# Vips::Image.get_value, Vips::Image.set_value, Vips::Image.bandsplit, 
# Vips::Image.maxpos, Vips::Image.minpos. 

module Vips

    TYPE_ARRAY_INT = GObject::type_from_name "VipsArrayInt"
    TYPE_ARRAY_DOUBLE = GObject::type_from_name "VipsArrayDouble"
    TYPE_ARRAY_IMAGE = GObject::type_from_name "VipsArrayImage"
    TYPE_BLOB = GObject::type_from_name "VipsBlob"
    TYPE_IMAGE = GObject::type_from_name "VipsImage"
    TYPE_OPERATION = GObject::type_from_name "VipsOperation"

    public

    # If +msg+ is not supplied, grab and clear the vips error buffer instead. 

    class Error < RuntimeError
        def initialize(msg = nil)
            if msg
                @details = msg
            elsif Vips::error_buffer != ""
                @details = Vips::error_buffer
                Vips::error_clear
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
        # Fetch arg list, remove boring ones, sort into priority order.
        def get_args
            object_class = GObject::object_class_from_instance self
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

    # internal call entry ... see Vips::call for the public entry point
    private
    def self.call_base(name, instance, option_string, supplied_values)
        log "in Vips::call_base"
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
                GObject::type_is_a(x.prop.value_type, Vips::TYPE_IMAGE)
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

        # look up in cache
        old_op = Vips::cache_operation_lookup op
        if old_op
            # junk the op we built, use the old op instead
            log "cache hit ... reusing old op"
            op = old_op
            old_op = nil

            # rescan args
            all_args = op.get_args()

            # find optional output args
            optional_output = all_args.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) == 0 
            end
            optional_output = Hash[
                optional_output.map(&:name).zip(optional_output)]
        else
            # it's a new op ... build and add to the cache
            log "cache miss ... building and adding to cache"
            if op.build != 0
                log "build failed"
                raise Vips::Error
            end

            Vips::cache_operation_add op
        end

        # gather output args 
        out = []

        all_args.each do |arg|
            # required output
            if (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) != 0 
                log "fetching required output #{arg.name}"
                out << arg.get_value
            end

            # modified input arg ... this will get the result of the 
            # copy() we did in Argument.set_value above
            if (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:modify]) != 0 
                out << arg.get_value
            end
        end

        optional_values.each do |name, value|
            # we are passed symbols as keys
            name = name.to_s
            if optional_output.has_key? name
                out << optional_output[name].get_value
            end
        end

        if out.length == 1
            out = out[0]
        elsif out.length == 0
            out = nil
        end

        # unref everything now we have refs to all outputs we want
        op.unref_outputs

        log "success! #{name}.out = #{out}"

        return out
    end

    public

    # :call-seq:
    #   call(operation_name, required_arg1, ..., required_argn, optional_args) => result
    #
    # This is the public entry point for the vips8 binding. Vips::call will run
    # any vips operation, for example
    #
    #   out = Vips::call "black", 100, 100, :bands => 12
    #
    # will call the C function 
    #
    #   vips_black( &out, 100, 100, "bands", 12, NULL );
    # 
    # There are Vips::Image#method_missing hooks which will run ::call for you 
    # on Vips::Image for undefined instance or class methods. So you can also 
    # write:
    #
    #   out = Vips::Image.black 100, 100, :bands => 12
    #
    # Or perhaps:
    #
    #   x = Vips::Image.black 100, 100
    #   y = x.invert
    #
    # to run the <tt>vips_invert()</tt> operator.
    #
    # There are also a set of operator overloads and some convenience functions,
    # see Vips::Image. 
    #
    # If the operator needs a vector constant, ::call will turn a scalar into a
    # vector for you. So for <tt>x.linear(a, b)</tt>, which calculates 
    # <tt>x * a + b</tt> where +a+ and +b+ are vector constants, you can write:
    #
    #   x = Vips::Image.black 100, 100, bands => 3
    #   y = x.linear(1, 2)
    #   y = x.linear([1], 4)
    #   y = x.linear([1, 2, 3], 4)
    #
    # or any other combination. The operator overloads use this facility to
    # support all the variations on:
    #
    #   x = Vips::Image.black 100, 100, bands => 3
    #   y = x * 2
    #   y = x + [1,2,3]
    #   y = x % [1]
    #
    # Similarly, whereever an image is required, you can use a constant. The
    # constant will be expanded to an image matching the first input image
    # argument. For example, you can write:
    #
    #   x = Vips::Image.black 100, 100, bands => 3
    #   y = x.bandjoin(255)
    #
    # to add an extra band to the image where each pixel in the new band has 
    # the constant value 255. 

    def self.call(name, *args)
        Vips::call_base name, nil, "", args
    end

    class Image
        private

        # handy for overloads ... want to be able to apply a function to an 
        # array or to a scalar
        def self.smap(x, &block)
            x.is_a?(Array) ? x.map {|x| smap(x, &block)} : block.(x)
        end

        public

        # Invoke a vips operation with Vips::call, using #self as the first 
        # input image argument. 
        def method_missing(name, *args)
            Vips::call_base(name.to_s, self, "", args)
        end

        # Invoke a vips operation with ::call.
        def self.method_missing(name, *args)
            Vips::call_base name.to_s, nil, "", args
        end

        # Return a new Vips::Image for a file on disc. This method can load
        # images in any format supported by vips. The filename can include
        # load options, for example:
        #
        #   image = Vips::new_from_file "fred.jpg[shrink=2]"
        #
        # You can also supply options as a hash, for example:
        #
        #   image = Vips::new_from_file "fred.jpg", :shrink => 2
        #
        # The options available depend upon the load operation that will be
        # executed. Try something like:
        #
        #   $ vips jpegload
        #
        # at the command-line to see a summary of the available options.
        #
        # Loading is fast: only enough of the image is loaded to be able to fill
        # out the header. Pixels will only be processed when they are needed.
        def self.new_from_file(name, *args)
            # very common, and Vips::filename_get_filename will segv if we pass
            # this
            if name == nil
                raise Error, "filename is nil"
            end
            filename = Vips::filename_get_filename name
            option_string = Vips::filename_get_options name
            loader = Vips::Foreign.find_load filename
            if loader == nil
                raise Vips::Error
            end

            Vips::call_base loader, nil, option_string, [filename] + args
        end

        # Create a new Vips::Image for an image encoded in a format, such as
        # JPEG, in a memory string. Load options may be passed encoded as
        # strings, or appended as a hash. For example:
        #
        #   image = Vips::new_from_from_buffer memory_buffer, "shrink=2"
        # 
        # or alternatively:
        #
        #   image = Vips::new_from_from_buffer memory_buffer, "", :shrink => 2
        #
        # The options available depend on the file format. Try something like:
        #
        #   $ vips jpegload_buffer
        #
        # at the command-line to see the availeble options. Only JPEG, PNG and
        # TIFF images can be read from memory buffers. 
        #
        # Loading is fast: only enough of the image is loaded to be able to fill
        # out the header. Pixels will only be processed when they are needed.
        def self.new_from_buffer(data, option_string, *args)
            loader = Vips::Foreign.find_load_buffer data
            if loader == nil
                raise Vips::Error
            end

            Vips::call_base loader, nil, option_string, [data] + args
        end

        # Create a new Vips::Image from a 1D or 2D array. A 1D array becomes an
        # image with height 1. Use +scale+ and +offset+ to set the scale and
        # offset fields in the header. These are useful for integer
        # convolutions. 
        #
        # For example:
        #
        #   image = Vips::new_from_from_array [1, 2, 3]
        #
        # or
        #
        #   image = Vips::new_from_from_array [
        #       [-1, -1, -1],
        #       [-1, 16, -1],
        #       [-1, -1, -1]], 8
        #
        # for a simple sharpening mask.
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

            image = Vips::Image.new_matrix_from_array width, height, array

            # be careful to set them as double
            image.set_double 'scale', scale.to_f
            image.set_double 'offset', offset.to_f

            return image
        end

        # Write this image to a file. Save options may be encoded in the
        # filename or given as a hash. For example:
        #
        #   image.write_to_file "fred.jpg[Q=90]"
        #
        # or equivalently:
        #
        #   image.write_to_file "fred.jpg", :Q => 90
        #
        # The save options depend on the selected saver. Try something like:
        #
        #   $ vips jpegsave
        #
        # to see all the available options. 
        def write_to_file(name, *args)
            filename = Vips::filename_get_filename name
            option_string = Vips::filename_get_options name
            saver = Vips::Foreign.find_save filename
            if saver == nil
                raise Vips::Error, "No known saver for '#{filename}'."
            end

            Vips::call_base saver, self, option_string, [filename] + args
        end

        # Write this image to a memory buffer. Save options may be encoded in 
        # the format_string or given as a hash. For example:
        #
        #   buffer = image.write_to_buffer ".jpg[Q=90]"
        #
        # or equivalently:
        #
        #   image.write_to_buffer ".jpg", :Q => 90
        #
        # The save options depend on the selected saver. Try something like:
        #
        #   $ vips jpegsave
        #
        # to see all the available options. 
        def write_to_buffer(format_string, *args)
            filename = Vips::filename_get_filename format_string
            option_string = Vips::filename_get_options format_string
            saver = Vips::Foreign.find_save_buffer filename
            if saver == nil
                raise Vips::Error, "No known saver for '#{filename}'."
            end

            Vips::call_base saver, self, option_string, args
        end

        ##
        # :method: width
        # :call-seq:
        #    width => integer
        #
        # Image width, in pixels. 

        ##
        # :method: height
        # :call-seq:
        #    height => integer
        #
        # Image height, in pixels. 

        ##
        # :method: bands
        # :call-seq:
        #    bands => integer
        #
        # Number of image bands (channels). 

        ##
        # :method: format
        # :call-seq:
        #    format => Vips::BandFormat
        #
        # Image pixel format. For example, an 8-bit unsigned image has the
        # :uchar format. 

        ##
        # :method: interpretation
        # :call-seq:
        #    interpretation => Vips::Interpretation
        #
        # Image interpretation. 

        ##
        # :method: coding
        # :call-seq:
        #    coding => Vips::Coding
        #
        # Image coding. 

        ##
        # :method: filename
        # :call-seq:
        #    filename => string
        #
        # The name of the file this image was originally loaded from.

        ##
        # :method: xres
        # :call-seq:
        #    xres => float
        #
        # The horizontal resolution of the image, in pixels per millimetre. 

        ##
        # :method: yres
        # :call-seq:
        #    yres => float
        #
        # The vertical resolution of the image, in pixels per millimetre. 

        # Set a metadata item on an image. Ruby types are automatically
        # transformed into the matching GValue, if possible. 
        #
        # For example, you can use this to set an image's ICC profile:
        #
        #   x = y.set_value "icc-profile-data", profile
        #
        # where +profile+ is an ICC profile held as a binary string object.
        #
        # If you need more control over the conversion process, use #set to 
        # set a GValue directly.
        def set_value(name, value)
            gtype = get_typeof name
            if gtype != 0
                # array-ize
                value = Argument::arrayize prop.value_type, value

                # blob-ize
                if GObject::type_is_a(gtype, Vips::TYPE_BLOB)
                    if not value.is_a? Vips::Blob
                        value = Vips::Blob.new(nil, value)
                    end
                end

                # image-ize
                if GObject::type_is_a(gtype, Vips::TYPE_IMAGE)
                    if not value.is_a? Vips::Image
                        value = Argument::imageize self, value
                    end
                end
            end

            set name, value
        end

        # Get a metadata item from an image. Ruby types are constructed 
        # automatically from the GValue, if possible. 
        #
        # For example, you can read the ICC profile from an image like this:
        #
        #    profile = image.get_value "icc-profile-data"
        #
        # and profile will be a binary string containing the profile. 
        #
        # Use #get to fetch a GValue directly.
        def get_value(name)
            # get the GValue
            value = get name

            # pull out the value
            value = value.get_value

            Argument::unwrap(value)
        end

        # Add an image, constant or array. 
        def +(other)
            other.is_a?(Vips::Image) ? add(other) : linear(1, other)
        end

        # Subtract an image, constant or array. 
        def -(other)
            other.is_a?(Vips::Image) ? 
                subtract(other) : linear(1, smap(other) {|x| x * -1})
        end

        # Multiply an image, constant or array. 
        def *(other)
            other.is_a?(Vips::Image) ? multiply(other) : linear(other, 0)
        end

        # Divide an image, constant or array. 
        def /(other)
            other.is_a?(Vips::Image) ? 
                divide(other) : linear(smap(other) {|x| 1.0 / x}, 0)
        end

        # Remainder after integer division with an image, constant or array. 
        def %(other)
            other.is_a?(Vips::Image) ? 
                remainder(other) : remainder_const(other)
        end

        # Raise to power of an image, constant or array. 
        def **(other)
            other.is_a?(Vips::Image) ? 
                math2(other, :pow) : math2_const(other, :pow)
        end

        # Integer left shift with an image, constant or array. 
        def <<(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :lshift) : boolean_const(other, :lshift)
        end

        # Integer right shift with an image, constant or array. 
        def >>(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :rshift) : boolean_const(other, :rshift)
        end

        # Integer bitwise OR with an image, constant or array. 
        def |(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :or) : boolean_const(other, :or)
        end

        # Integer bitwise AND with an image, constant or array. 
        def &(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :and) : boolean_const(other, :and)
        end

        # Integer bitwise EOR with an image, constant or array. 
        def ^(other)
            other.is_a?(Vips::Image) ? 
                boolean(other, :eor) : boolean_const(other, :eor)
        end

        # Equivalent to image ^ -1
        def !
            self ^ -1
        end

        # Equivalent to image ^ -1
        def ~
            self ^ -1
        end

        def +@
            self
        end

        # Equivalent to image * -1
        def -@
            self * -1
        end

        # Relational less than with an image, constant or array. 
        def <(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :less) : relational_const(other, :less)
        end

        # Relational less than or equal to with an image, constant or array. 
        def <=(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :lesseq) : relational_const(other, :lesseq)
        end

        # Relational more than with an image, constant or array. 
        def >(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :more) : relational_const(other, :more)
        end

        # Relational more than or equal to with an image, constant or array. 
        def >(other)
            other.is_a?(Vips::Image) ? 
                relational(other, :moreeq) : relational_const(other, :moreeq)
        end

        # Compare equality to nil, an image, constant or array.
        def ==(other)
            if other == nil
                false
            elsif other.is_a?(Vips::Image)  
                relational(other, :equal) 
            else
                relational_const(other, :equal)
            end
        end

        # Compare inequality to nil, an image, constant or array.
        def !=(other)
            if other == nil
                true
            elsif other.is_a?(Vips::Image) 
                relational(other, :noteq) 
            else
                relational_const(other, :noteq)
            end
        end

        # Return the largest integral value not greater than the argument.
        def floor
            round :floor
        end

        # Return the smallest integral value not less than the argument.
        def ceil
            round :ceil
        end

        # Return the nearest integral value.
        def rint
            round :rint
        end

        # :call-seq:
        #   bandsplit => [image]
        #
        # Split an n-band image into n separate images.
        def bandsplit
            (0...bands).map {|i| extract_band(i)}
        end

        # :call-seq:
        #   bandjoin(image) => out
        #   bandjoin(const_array) => out
        #   bandjoin(image_array) => out
        #
        # Join a set of images bandwise.
        def bandjoin(other)
            if not other.is_a? Array
                other = [other]
            end

            Vips::Image.bandjoin([self] + other)
        end

        # Return the coordinates of the image maximum.
        def maxpos
            v, opts = max :x => True, :y => True
            x = opts['x']
            y = opts['y']
            return v, x, y
        end

        # Return the coordinates of the image minimum.
        def minpos
            v, opts = min :x => True, :y => True
            x = opts['x']
            y = opts['y']
            return v, x, y
        end

        # Return the real part of a complex image.
        def real
            complexget :real
        end

        # Return the imaginary part of a complex image.
        def imag
            complexget :imag
        end

        # Return an image converted to polar coordinates.
        def polar
            complex :polar
        end

        # Return an image converted to rectangular coordinates.
        def rect
            complex :rect 
        end

        # Return the complex conjugate of an image.
        def conj
            complex :conj 
        end

        # Return the sine of an image in degrees.
        def sin
            math :sin 
        end

        # Return the cosine of an image in degrees.
        def cos
            math :cos
        end

        # Return the tangent of an image in degrees.
        def tan
            math :tan
        end

        # Return the inverse sine of an image in degrees.
        def asin
            math :asin
        end

        # Return the inverse cosine of an image in degrees.
        def acos
            math :acos
        end

        # Return the inverse tangent of an image in degrees.
        def atan
            math :atan
        end

        # Return the natural log of an image.
        def log
            math :log
        end

        # Return the log base 10 of an image.
        def log10
            math :log10
        end

        # Return e ** pixel.
        def exp
            math :exp
        end

        # Return 10 ** pixel.
        def exp10
            math :exp10
        end

        # Select pixels from +th+ if +self+ is non-zero and from +el+ if
        # +self+ is zero. Use the :blend option to fade smoothly 
        # between +th+ and +el+. 
        def ifthenelse(th, el, *args) 
            match_image = [th, el, self].find {|x| x.is_a? Vips::Image}

            if not th.is_a? Vips::Image
                th = Argument::imageize match_image, th
            end
            if not el.is_a? Vips::Image
                el = Argument::imageize match_image, el
            end

            Vips::call_base "ifthenelse", self, "", [th, el] + args
        end

    end

    # This method generates rdoc comments for all the dynamically bound
    # vips operations. 

    #--
    # See the comment in the next section.
    #++

    def self.generate_rdoc
        no_generate = ["bandjoin", "ifthenelse"]

        generate_operation = lambda do |op|
            flags = op.get_flags
            # need a bit pattern, not a symbolic name
            flags = Vips::OperationFlags.to_native flags, 1
            return if (flags & Vips::OperationFlags[:deprecated]) != 0

            gtype = GObject::type_from_instance op
            nickname = Vips::nickname_find gtype

            return if no_generate.include? nickname

            all_args = op.get_args.select {|arg| not arg.isset}

            # separate args into various categories
 
            required_input = all_args.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) != 0 
            end

            optional_input = all_args.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:input]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) == 0 
            end

            required_output = all_args.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) != 0 
            end

            # required input args with :modify are copied and appended to 
            # output
            modified_required_input = required_input.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:modify]) != 0 
            end
            required_output += modified_required_input

            optional_output = all_args.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:output]) != 0 and
                (arg.flags & Vips::ArgumentFlags[:required]) == 0 
            end

            # optional input args with :modify are copied and appended to 
            # output
            modified_optional_input = optional_input.select do |arg|
                (arg.flags & Vips::ArgumentFlags[:modify]) != 0 
            end
            optional_output += modified_optional_input

            # find the first input image, if any ... we will be a method of this
            # instance
            member_x = required_input.find do |x|
                GObject::type_is_a(x.prop.value_type, Vips::TYPE_IMAGE)
            end
            if member_x != nil
                required_input.delete member_x
            end

            description = op.get_description

            puts "##"
            if member_x 
                puts "# :method: #{nickname}"
            else
                puts "# :singleton-method: #{nickname}"
            end
            puts "# :call-seq:"
            input = required_input.map(&:name).join(", ")
            output = required_output.map(&:name).join(", ")
            puts "#    #{nickname}(#{input}) => #{output}"
            puts "#"
            puts "# #{description.capitalize}."
            if required_input.length > 0 
                puts "#"
                puts "# Input:"
                required_input.each {|arg| puts "# #{arg.description}"}
            end
            if required_output.length > 0 
                puts "#"
                puts "# Output:"
                required_output.each {|arg| puts "# #{arg.description}"}
            end
            if optional_input.length > 0 
                puts "#"
                puts "# Options:"
                optional_input.each {|arg| puts "# #{arg.description}"}
            end
            if optional_output.length > 0 
                puts "#"
                puts "# Output options:"
                optional_output.each {|arg| puts "# #{arg.description}"}
            end
            puts ""
        end

        generate_class = lambda do |gtype|
            name = GObject::type_name gtype
            # can be nil for abstract types
            # can't find a way to get to #abstract? from a gtype
            op = Vips::Operation.new name
            Vips::error_clear

            generate_operation.(op) if op != nil

            (GObject::type_children gtype).each do |x|
                generate_class.(x)
            end
        end

        puts "#--"
        puts "# This file generated automatically. Do not edit!"
        puts "#++"
        puts ""

        generate_class.(TYPE_OPERATION)
    end

end

#--
# It'd be nice if we could have these doc comments in a separate file and use
# rdoc :include: to pull them in, but it seems that rdoc will only allow one
# method doc per :include:
#++

module Vips
    class Image

        #--
        # These comments generated by Vips::generate_rdoc above. Regenerate with
        # something like: 
        #
        #   ruby > dynamic-method-docs
        #   require 'vips8'
        #   Vips::generate_rodc
        #   ^D
        #
        # then copy-paste.
        #++

        ##
        # :singleton-method: system
        # :call-seq:
        #    system(cmd-format) => 
        #
        # Run an external command.
        #
        # Input:
        # [cmd-format] Command to run, input gchararray
        #
        # Options:
        # [in] Array of input images, input VipsArrayImage
        # [in-format] Format for input filename, input gchararray
        # [out-format] Format for output filename, input gchararray
        #
        # Output options:
        # [out] Output image, output VipsImage
        # [log] Command log, output gchararray

        ##
        # :method: add
        # :call-seq:
        #    add(right) => out
        #
        # Add two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: subtract
        # :call-seq:
        #    subtract(right) => out
        #
        # Subtract two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: multiply
        # :call-seq:
        #    multiply(right) => out
        #
        # Multiply two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: divide
        # :call-seq:
        #    divide(right) => out
        #
        # Divide two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: relational
        # :call-seq:
        #    relational(right, relational) => out
        #
        # Relational operation on two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        # [relational] relational to perform, input VipsOperationRelational
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: remainder
        # :call-seq:
        #    remainder(right) => out
        #
        # Remainder after integer division of two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: boolean
        # :call-seq:
        #    boolean(right, boolean) => out
        #
        # Boolean operation on two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        # [boolean] boolean to perform, input VipsOperationBoolean
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: math2
        # :call-seq:
        #    math2(right, math2) => out
        #
        # Binary math operations.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        # [math2] math to perform, input VipsOperationMath2
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: complex2
        # :call-seq:
        #    complex2(right, cmplx) => out
        #
        # Complex binary operations on two images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        # [cmplx] binary complex operation to perform, input VipsOperationComplex2
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: complexform
        # :call-seq:
        #    complexform(right) => out
        #
        # Form a complex image from two real images.
        #
        # Input:
        # [right] Right-hand image argument, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :singleton-method: sum
        # :call-seq:
        #    sum(in) => out
        #
        # Sum an array of images.
        #
        # Input:
        # [in] Array of input images, input VipsArrayImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: invert
        # :call-seq:
        #    invert() => out
        #
        # Invert an image.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: linear
        # :call-seq:
        #    linear(a, b) => out
        #
        # Calculate (a * in + b).
        #
        # Input:
        # [a] Multiply by this, input VipsArrayDouble
        # [b] Add this, input VipsArrayDouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output should be uchar, input gboolean

        ##
        # :method: math
        # :call-seq:
        #    math(math) => out
        #
        # Apply a math operation to an image.
        #
        # Input:
        # [math] math to perform, input VipsOperationMath
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: abs
        # :call-seq:
        #    abs() => out
        #
        # Absolute value of an image.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: sign
        # :call-seq:
        #    sign() => out
        #
        # Unit vector of pixel.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: round
        # :call-seq:
        #    round(round) => out
        #
        # Perform a round function on an image.
        #
        # Input:
        # [round] rounding operation to perform, input VipsOperationRound
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: relational_const
        # :call-seq:
        #    relational_const(c, relational) => out
        #
        # Relational operations against a constant.
        #
        # Input:
        # [c] Array of constants, input VipsArrayDouble
        # [relational] relational to perform, input VipsOperationRelational
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: remainder_const
        # :call-seq:
        #    remainder_const(c) => out
        #
        # Remainder after integer division of an image and a constant.
        #
        # Input:
        # [c] Array of constants, input VipsArrayDouble
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: boolean_const
        # :call-seq:
        #    boolean_const(c, boolean) => out
        #
        # Boolean operations against a constant.
        #
        # Input:
        # [c] Array of constants, input VipsArrayDouble
        # [boolean] boolean to perform, input VipsOperationBoolean
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: math2_const
        # :call-seq:
        #    math2_const(c, math2) => out
        #
        # Pow( @in, @c ).
        #
        # Input:
        # [c] Array of constants, input VipsArrayDouble
        # [math2] math to perform, input VipsOperationMath2
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: complex
        # :call-seq:
        #    complex(cmplx) => out
        #
        # Perform a complex operation on an image.
        #
        # Input:
        # [cmplx] complex to perform, input VipsOperationComplex
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: complexget
        # :call-seq:
        #    complexget(get) => out
        #
        # Get a component from a complex image.
        #
        # Input:
        # [get] complex to perform, input VipsOperationComplexget
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: avg
        # :call-seq:
        #    avg() => out
        #
        # Find image average.
        #
        # Output:
        # [out] Output value, output gdouble

        ##
        # :method: min
        # :call-seq:
        #    min() => out
        #
        # Find image minimum.
        #
        # Output:
        # [out] Output value, output gdouble
        #
        # Options:
        # [size] Number of minimum values to find, input gint
        #
        # Output options:
        # [x] Horizontal position of minimum, output gint
        # [y] Vertical position of minimum, output gint
        # [out-array] Array of output values, output VipsArrayDouble
        # [x-array] Array of horizontal positions, output VipsArrayInt
        # [y-array] Array of vertical positions, output VipsArrayInt

        ##
        # :method: max
        # :call-seq:
        #    max() => out
        #
        # Find image maximum.
        #
        # Output:
        # [out] Output value, output gdouble
        #
        # Options:
        # [size] Number of maximum values to find, input gint
        #
        # Output options:
        # [x] Horizontal position of maximum, output gint
        # [y] Vertical position of maximum, output gint
        # [out-array] Array of output values, output VipsArrayDouble
        # [x-array] Array of horizontal positions, output VipsArrayInt
        # [y-array] Array of vertical positions, output VipsArrayInt

        ##
        # :method: deviate
        # :call-seq:
        #    deviate() => out
        #
        # Find image standard deviation.
        #
        # Output:
        # [out] Output value, output gdouble

        ##
        # :method: stats
        # :call-seq:
        #    stats() => out
        #
        # Find image average.
        #
        # Output:
        # [out] Output array of statistics, output VipsImage

        ##
        # :method: hist_find
        # :call-seq:
        #    hist_find() => out
        #
        # Find image histogram.
        #
        # Output:
        # [out] Output histogram, output VipsImage
        #
        # Options:
        # [band] Find histogram of band, input gint

        ##
        # :method: hist_find_ndim
        # :call-seq:
        #    hist_find_ndim() => out
        #
        # Find n-dimensional image histogram.
        #
        # Output:
        # [out] Output histogram, output VipsImage
        #
        # Options:
        # [bins] Number of bins in each dimension, input gint

        ##
        # :method: hist_find_indexed
        # :call-seq:
        #    hist_find_indexed(index) => out
        #
        # Find indexed image histogram.
        #
        # Input:
        # [index] Index image, input VipsImage
        #
        # Output:
        # [out] Output histogram, output VipsImage

        ##
        # :method: hough_line
        # :call-seq:
        #    hough_line() => out
        #
        # Find hough line transform.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [width] horizontal size of parameter space, input gint
        # [height] Vertical size of parameter space, input gint

        ##
        # :method: hough_circle
        # :call-seq:
        #    hough_circle() => out
        #
        # Find hough circle transform.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [scale] Scale down dimensions by this factor, input gint
        # [min-radius] Smallest radius to search for, input gint
        # [max-radius] Largest radius to search for, input gint

        ##
        # :method: project
        # :call-seq:
        #    project() => columns, rows
        #
        # Find image projections.
        #
        # Output:
        # [columns] Sums of columns, output VipsImage
        # [rows] Sums of rows, output VipsImage

        ##
        # :method: profile
        # :call-seq:
        #    profile() => columns, rows
        #
        # Find image profiles.
        #
        # Output:
        # [columns] First non-zero pixel in column, output VipsImage
        # [rows] First non-zero pixel in row, output VipsImage

        ##
        # :method: measure
        # :call-seq:
        #    measure(h, v) => out
        #
        # Measure a set of patches on a color chart.
        #
        # Input:
        # [h] Number of patches across chart, input gint
        # [v] Number of patches down chart, input gint
        #
        # Output:
        # [out] Output array of statistics, output VipsImage
        #
        # Options:
        # [left] Left edge of extract area, input gint
        # [top] Top edge of extract area, input gint
        # [width] Width of extract area, input gint
        # [height] Height of extract area, input gint

        ##
        # :method: getpoint
        # :call-seq:
        #    getpoint(x, y) => out-array
        #
        # Read a point from an image.
        #
        # Input:
        # [x] Point to read, input gint
        # [y] Point to read, input gint
        #
        # Output:
        # [out-array] Array of output values, output VipsArrayDouble

        ##
        # :method: copy
        # :call-seq:
        #    copy() => out
        #
        # Copy an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [swap] Swap bytes in image between little and big-endian, input gboolean
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [bands] Number of bands in image, input gint
        # [format] Pixel format in image, input VipsBandFormat
        # [coding] Pixel coding, input VipsCoding
        # [interpretation] Pixel interpretation, input VipsInterpretation
        # [xres] Horizontal resolution in pixels/mm, input gdouble
        # [yres] Vertical resolution in pixels/mm, input gdouble
        # [xoffset] Horizontal offset of origin, input gint
        # [yoffset] Vertical offset of origin, input gint

        ##
        # :method: blockcache
        # :call-seq:
        #    blockcache() => out
        #
        # Cache an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [tile-height] Tile height in pixels, input gint
        # [access] Expected access pattern, input VipsAccess
        # [threaded] Allow threaded access, input gboolean
        # [persistent] Keep cache between evaluations, input gboolean

        ##
        # :method: tilecache
        # :call-seq:
        #    tilecache() => out
        #
        # Cache an image as a set of tiles.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [tile-width] Tile width in pixels, input gint
        # [tile-height] Tile height in pixels, input gint
        # [max-tiles] Maximum number of tiles to cache, input gint
        # [access] Expected access pattern, input VipsAccess
        # [threaded] Allow threaded access, input gboolean
        # [persistent] Keep cache between evaluations, input gboolean

        ##
        # :method: linecache
        # :call-seq:
        #    linecache() => out
        #
        # Cache an image as a set of lines.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [tile-height] Tile height in pixels, input gint
        # [access] Expected access pattern, input VipsAccess
        # [threaded] Allow threaded access, input gboolean
        # [persistent] Keep cache between evaluations, input gboolean

        ##
        # :method: sequential
        # :call-seq:
        #    sequential() => out
        #
        # Check sequential access.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [trace] trace pixel requests, input gboolean
        # [tile-height] Tile height in pixels, input gint
        # [access] Expected access pattern, input VipsAccess

        ##
        # :method: cache
        # :call-seq:
        #    cache() => out
        #
        # Cache an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [tile-width] Tile width in pixels, input gint
        # [tile-height] Tile height in pixels, input gint
        # [max-tiles] Maximum number of tiles to cache, input gint

        ##
        # :method: embed
        # :call-seq:
        #    embed(x, y, width, height) => out
        #
        # Embed an image in a larger image.
        #
        # Input:
        # [x] Left edge of input in output, input gint
        # [y] Top edge of input in output, input gint
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [extend] How to generate the extra pixels, input VipsExtend
        # [background] Colour for background pixels, input VipsArrayDouble

        ##
        # :method: flip
        # :call-seq:
        #    flip(direction) => out
        #
        # Flip an image.
        #
        # Input:
        # [direction] Direction to flip image, input VipsDirection
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: insert
        # :call-seq:
        #    insert(sub, x, y) => out
        #
        # Insert image @sub into @main at @x, @y.
        #
        # Input:
        # [sub] Sub-image to insert into main image, input VipsImage
        # [x] Left edge of sub in main, input gint
        # [y] Top edge of sub in main, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [expand] Expand output to hold all of both inputs, input gboolean
        # [background] Colour for new pixels, input VipsArrayDouble

        ##
        # :method: join
        # :call-seq:
        #    join(in2, direction) => out
        #
        # Join a pair of images.
        #
        # Input:
        # [in2] Second input image, input VipsImage
        # [direction] Join left-right or up-down, input VipsDirection
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [align] Align on the low, centre or high coordinate edge, input VipsAlign
        # [expand] Expand output to hold all of both inputs, input gboolean
        # [shim] Pixels between images, input gint
        # [background] Colour for new pixels, input VipsArrayDouble

        ##
        # :method: extract_area
        # :call-seq:
        #    extract_area(left, top, width, height) => out
        #
        # Extract an area from an image.
        #
        # Input:
        # [left] Left edge of extract area, input gint
        # [top] Top edge of extract area, input gint
        # [width] Width of extract area, input gint
        # [height] Height of extract area, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: extract_area
        # :call-seq:
        #    extract_area(left, top, width, height) => out
        #
        # Extract an area from an image.
        #
        # Input:
        # [left] Left edge of extract area, input gint
        # [top] Top edge of extract area, input gint
        # [width] Width of extract area, input gint
        # [height] Height of extract area, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: extract_band
        # :call-seq:
        #    extract_band(band) => out
        #
        # Extract band from an image.
        #
        # Input:
        # [band] Band to extract, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [n] Number of bands to extract, input gint

        ##
        # :singleton-method: bandrank
        # :call-seq:
        #    bandrank(in) => out
        #
        # Band-wise rank of a set of images.
        #
        # Input:
        # [in] Array of input images, input VipsArrayImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [index] Select this band element from sorted list, input gint

        ##
        # :method: bandmean
        # :call-seq:
        #    bandmean() => out
        #
        # Band-wise average.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: bandbool
        # :call-seq:
        #    bandbool(boolean) => out
        #
        # Boolean operation across image bands.
        #
        # Input:
        # [boolean] boolean to perform, input VipsOperationBoolean
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: replicate
        # :call-seq:
        #    replicate(across, down) => out
        #
        # Replicate an image.
        #
        # Input:
        # [across] Repeat this many times horizontally, input gint
        # [down] Repeat this many times vertically, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: cast
        # :call-seq:
        #    cast(format) => out
        #
        # Cast an image.
        #
        # Input:
        # [format] Format to cast to, input VipsBandFormat
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: rot
        # :call-seq:
        #    rot(angle) => out
        #
        # Rotate an image.
        #
        # Input:
        # [angle] Angle to rotate image, input VipsAngle
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: rot45
        # :call-seq:
        #    rot45() => out
        #
        # Rotate an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [angle] Angle to rotate image, input VipsAngle45

        ##
        # :method: autorot
        # :call-seq:
        #    autorot() => out
        #
        # Autorotate image by exif tag.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Output options:
        # [angle] Angle image was rotated by, output VipsAngle

        ##
        # :method: recomb
        # :call-seq:
        #    recomb(m) => out
        #
        # Linear recombination with matrix.
        #
        # Input:
        # [m] matrix of coefficients, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: flatten
        # :call-seq:
        #    flatten() => out
        #
        # Flatten alpha out of an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: grid
        # :call-seq:
        #    grid(tile-height, across, down) => out
        #
        # Grid an image.
        #
        # Input:
        # [tile-height] chop into tiles this high, input gint
        # [across] number of tiles across, input gint
        # [down] number of tiles down, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: scale
        # :call-seq:
        #    scale() => out
        #
        # Scale an image to uchar.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [log] Log scale, input gboolean
        # [exp] Exponent for log scale, input gdouble

        ##
        # :method: wrap
        # :call-seq:
        #    wrap() => out
        #
        # Wrap image origin.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [x] Left edge of input in output, input gint
        # [y] Top edge of input in output, input gint

        ##
        # :method: zoom
        # :call-seq:
        #    zoom(xfac, yfac) => out
        #
        # Zoom an image.
        #
        # Input:
        # [xfac] Horizontal zoom factor, input gint
        # [yfac] Vertical zoom factor, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: subsample
        # :call-seq:
        #    subsample(xfac, yfac) => out
        #
        # Subsample an image.
        #
        # Input:
        # [xfac] Horizontal subsample factor, input gint
        # [yfac] Vertical subsample factor, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [point] Point sample, input gboolean

        ##
        # :method: msb
        # :call-seq:
        #    msb() => out
        #
        # Pick most-significant byte from an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [band] Band to msb, input gint

        ##
        # :method: falsecolour
        # :call-seq:
        #    falsecolour() => out
        #
        # False colour an image.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: gamma
        # :call-seq:
        #    gamma() => out
        #
        # Gamma an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [exponent] Gamma factor, input gdouble

        ##
        # :singleton-method: black
        # :call-seq:
        #    black(width, height) => out
        #
        # Make a black image.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [bands] Number of bands in image, input gint

        ##
        # :singleton-method: gaussnoise
        # :call-seq:
        #    gaussnoise(width, height) => out
        #
        # Make a gaussnoise image.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [mean] Mean of pixels in generated image, input gdouble
        # [sigma] Standard deviation of pixels in generated image, input gdouble

        ##
        # :singleton-method: text
        # :call-seq:
        #    text(text) => out
        #
        # Make a text image.
        #
        # Input:
        # [text] Text to render, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [width] Maximum image width in pixels, input gint
        # [font] Font to render width, input gchararray
        # [dpi] DPI to render at, input gint
        # [align] Align on the low, centre or high coordinate edge, input VipsAlign

        ##
        # :singleton-method: xyz
        # :call-seq:
        #    xyz(width, height) => out
        #
        # Make an image where pixel values are coordinates.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [csize] Size of third dimension, input gint
        # [dsize] Size of fourth dimension, input gint
        # [esize] Size of fifth dimension, input gint

        ##
        # :singleton-method: gaussmat
        # :call-seq:
        #    gaussmat(sigma, min-ampl) => out
        #
        # Make a gaussian image.
        #
        # Input:
        # [sigma] Sigma of Gaussian, input gdouble
        # [min-ampl] Minimum amplitude of Gaussian, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [separable] Generate separable Gaussian, input gboolean
        # [integer] Generate integer Gaussian, input gboolean

        ##
        # :singleton-method: logmat
        # :call-seq:
        #    logmat(sigma, min-ampl) => out
        #
        # Make a laplacian of gaussian image.
        #
        # Input:
        # [sigma] Radius of Logmatian, input gdouble
        # [min-ampl] Minimum amplitude of Logmatian, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [separable] Generate separable Logmatian, input gboolean
        # [integer] Generate integer Logmatian, input gboolean

        ##
        # :singleton-method: eye
        # :call-seq:
        #    eye(width, height) => out
        #
        # Make an image showing the eye's spatial response.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [factor] Maximum spatial frequency, input gdouble

        ##
        # :singleton-method: grey
        # :call-seq:
        #    grey(width, height) => out
        #
        # Make a grey ramp image.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean

        ##
        # :singleton-method: zone
        # :call-seq:
        #    zone(width, height) => out
        #
        # Make a zone plate.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean

        ##
        # :singleton-method: sines
        # :call-seq:
        #    sines(width, height) => out
        #
        # Make a 2d sine wave.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [hfreq] Horizontal spatial frequency, input gdouble
        # [vfreq] Vertical spatial frequency, input gdouble

        ##
        # :singleton-method: mask_ideal
        # :call-seq:
        #    mask_ideal(width, height, frequency-cutoff) => out
        #
        # Make an ideal filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff] Frequency cutoff, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean

        ##
        # :singleton-method: mask_ideal_ring
        # :call-seq:
        #    mask_ideal_ring(width, height, frequency-cutoff, ringwidth) => out
        #
        # Make an ideal ring filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff] Frequency cutoff, input gdouble
        # [ringwidth] Ringwidth, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean

        ##
        # :singleton-method: mask_ideal_band
        # :call-seq:
        #    mask_ideal_band(width, height, frequency-cutoff-x, frequency-cutoff-y, radius) => out
        #
        # Make an ideal band filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff-x] Frequency cutoff x, input gdouble
        # [frequency-cutoff-y] Frequency cutoff y, input gdouble
        # [radius] radius of circle, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean

        ##
        # :singleton-method: mask_butterworth
        # :call-seq:
        #    mask_butterworth(width, height, order, frequency-cutoff, amplitude-cutoff) => out
        #
        # Make a butterworth filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [order] Filter order, input gdouble
        # [frequency-cutoff] Frequency cutoff, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean

        ##
        # :singleton-method: mask_butterworth_ring
        # :call-seq:
        #    mask_butterworth_ring(width, height, order, frequency-cutoff, amplitude-cutoff, ringwidth) => out
        #
        # Make a butterworth ring filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [order] Filter order, input gdouble
        # [frequency-cutoff] Frequency cutoff, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        # [ringwidth] Ringwidth, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean

        ##
        # :singleton-method: mask_butterworth_band
        # :call-seq:
        #    mask_butterworth_band(width, height, order, frequency-cutoff-x, frequency-cutoff-y, radius, amplitude-cutoff) => out
        #
        # Make a butterworth_band filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [order] Filter order, input gdouble
        # [frequency-cutoff-x] Frequency cutoff x, input gdouble
        # [frequency-cutoff-y] Frequency cutoff y, input gdouble
        # [radius] radius of circle, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [reject] Invert the sense of the filter, input gboolean
        # [nodc] Remove DC component, input gboolean

        ##
        # :singleton-method: mask_gaussian
        # :call-seq:
        #    mask_gaussian(width, height, frequency-cutoff, amplitude-cutoff) => out
        #
        # Make a gaussian filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff] Frequency cutoff, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean

        ##
        # :singleton-method: mask_gaussian_ring
        # :call-seq:
        #    mask_gaussian_ring(width, height, frequency-cutoff, amplitude-cutoff, ringwidth) => out
        #
        # Make a gaussian ring filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff] Frequency cutoff, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        # [ringwidth] Ringwidth, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean

        ##
        # :singleton-method: mask_gaussian_band
        # :call-seq:
        #    mask_gaussian_band(width, height, frequency-cutoff-x, frequency-cutoff-y, radius, amplitude-cutoff) => out
        #
        # Make a gaussian filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [frequency-cutoff-x] Frequency cutoff x, input gdouble
        # [frequency-cutoff-y] Frequency cutoff y, input gdouble
        # [radius] radius of circle, input gdouble
        # [amplitude-cutoff] Amplitude cutoff, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean

        ##
        # :singleton-method: mask_fractal
        # :call-seq:
        #    mask_fractal(width, height, fractal-dimension) => out
        #
        # Make fractal filter.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [fractal-dimension] Fractal dimension, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [uchar] Output an unsigned char image, input gboolean
        # [nodc] Remove DC component, input gboolean
        # [reject] Invert the sense of the filter, input gboolean
        # [optical] Rotate quadrants to optical space, input gboolean

        ##
        # :method: buildlut
        # :call-seq:
        #    buildlut() => out
        #
        # Build a look-up table.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: invertlut
        # :call-seq:
        #    invertlut() => out
        #
        # Build an inverted look-up table.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [size] LUT size to generate, input gint

        ##
        # :singleton-method: tonelut
        # :call-seq:
        #    tonelut() => out
        #
        # Build a look-up table.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [in-max] Size of LUT to build, input gint
        # [out-max] Maximum value in output LUT, input gint
        # [Lb] Lowest value in output, input gdouble
        # [Lw] Highest value in output, input gdouble
        # [Ps] Position of shadow, input gdouble
        # [Pm] Position of mid-tones, input gdouble
        # [Ph] Position of highlights, input gdouble
        # [S] Adjust shadows by this much, input gdouble
        # [M] Adjust mid-tones by this much, input gdouble
        # [H] Adjust highlights by this much, input gdouble

        ##
        # :singleton-method: identity
        # :call-seq:
        #    identity() => out
        #
        # Make a 1d image where pixel values are indexes.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [bands] Number of bands in LUT, input gint
        # [ushort] Create a 16-bit LUT, input gboolean
        # [size] Size of 16-bit LUT, input gint

        ##
        # :singleton-method: fractsurf
        # :call-seq:
        #    fractsurf(width, height, fractal-dimension) => out
        #
        # Make a fractal surface.
        #
        # Input:
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [fractal-dimension] Fractal dimension, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :singleton-method: radload
        # :call-seq:
        #    radload(filename) => out
        #
        # Load a radiance image from a file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: ppmload
        # :call-seq:
        #    ppmload(filename) => out
        #
        # Load ppm from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: csvload
        # :call-seq:
        #    csvload(filename) => out
        #
        # Load csv from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [skip] Skip this many lines at the start of the file, input gint
        # [lines] Read this many lines from the file, input gint
        # [whitespace] Set of whitespace characters, input gchararray
        # [separator] Set of separator characters, input gchararray
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: matrixload
        # :call-seq:
        #    matrixload(filename) => out
        #
        # Load matrix from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: analyzeload
        # :call-seq:
        #    analyzeload(filename) => out
        #
        # Load an analyze6 image.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: rawload
        # :call-seq:
        #    rawload(filename, width, height, bands) => out
        #
        # Load raw data from a file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        # [width] Image width in pixels, input gint
        # [height] Image height in pixels, input gint
        # [bands] Number of bands in image, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [offset] Offset in bytes from start of file, input guint64
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: vipsload
        # :call-seq:
        #    vipsload(filename) => out
        #
        # Load vips from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: pngload
        # :call-seq:
        #    pngload(filename) => out
        #
        # Load png from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: pngload_buffer
        # :call-seq:
        #    pngload_buffer(buffer) => out
        #
        # Load png from buffer.
        #
        # Input:
        # [buffer] Buffer to load from, input VipsBlob
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: matload
        # :call-seq:
        #    matload(filename) => out
        #
        # Load mat from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: jpegload
        # :call-seq:
        #    jpegload(filename) => out
        #
        # Load jpeg from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [shrink] Shrink factor on load, input gint
        # [fail] Fail on first warning, input gboolean
        # [autorotate] Automatically rotate image using exif orientation, input gboolean
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: jpegload_buffer
        # :call-seq:
        #    jpegload_buffer(buffer) => out
        #
        # Load jpeg from buffer.
        #
        # Input:
        # [buffer] Buffer to load from, input VipsBlob
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [shrink] Shrink factor on load, input gint
        # [fail] Fail on first warning, input gboolean
        # [autorotate] Automatically rotate image using exif orientation, input gboolean
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: webpload
        # :call-seq:
        #    webpload(filename) => out
        #
        # Load webp from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: webpload_buffer
        # :call-seq:
        #    webpload_buffer(buffer) => out
        #
        # Load webp from buffer.
        #
        # Input:
        # [buffer] Buffer to load from, input VipsBlob
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: tiffload
        # :call-seq:
        #    tiffload(filename) => out
        #
        # Load tiff from file.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [page] Load this page from the image, input gint
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: tiffload_buffer
        # :call-seq:
        #    tiffload_buffer(buffer) => out
        #
        # Load tiff from buffer.
        #
        # Input:
        # [buffer] Buffer to load from, input VipsBlob
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [page] Load this page from the image, input gint
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: openslideload
        # :call-seq:
        #    openslideload(filename) => out
        #
        # Load file with openslide.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        # [level] Load this level from the file, input gint
        # [autocrop] Crop to image bounds, input gboolean
        # [associated] Load this associated image, input gchararray
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: magickload
        # :call-seq:
        #    magickload(filename) => out
        #
        # Load file with imagemagick.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [all-frames] Read all frames from an image, input gboolean
        # [density] Canvas resolution for rendering vector formats like SVG, input gchararray
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: fitsload
        # :call-seq:
        #    fitsload(filename) => out
        #
        # Load a fits image.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :singleton-method: openexrload
        # :call-seq:
        #    openexrload(filename) => out
        #
        # Load an openexr image.
        #
        # Input:
        # [filename] Filename to load from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [disc] Open to disc, input gboolean
        # [access] Required access pattern for this file, input VipsAccess
        #
        # Output options:
        # [flags] Flags for this file, output VipsForeignFlags

        ##
        # :method: radsave
        # :call-seq:
        #    radsave(filename) => 
        #
        # Save image to radiance file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: ppmsave
        # :call-seq:
        #    ppmsave(filename) => 
        #
        # Save image to ppm file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [ascii] save as ascii, input gboolean
        # [squash] save as one bit, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: csvsave
        # :call-seq:
        #    csvsave(filename) => 
        #
        # Save image to csv file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [separator] Separator characters, input gchararray
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: matrixsave
        # :call-seq:
        #    matrixsave(filename) => 
        #
        # Save image to matrix file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: matrixprint
        # :call-seq:
        #    matrixprint() => 
        #
        # Print matrix.
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: rawsave
        # :call-seq:
        #    rawsave(filename) => 
        #
        # Save image to raw file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: rawsave_fd
        # :call-seq:
        #    rawsave_fd(fd) => 
        #
        # Write raw image to file descriptor.
        #
        # Input:
        # [fd] File descriptor to write to, input gint
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: vipssave
        # :call-seq:
        #    vipssave(filename) => 
        #
        # Save image to vips file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: dzsave
        # :call-seq:
        #    dzsave(filename) => 
        #
        # Save image to deep zoom format.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [layout] Directory layout, input VipsForeignDzLayout
        # [suffix] Filename suffix for tiles, input gchararray
        # [overlap] Tile overlap in pixels, input gint
        # [tile-size] Tile size in pixels, input gint
        # [background] Colour for background pixels, input VipsArrayDouble
        # [centre] Center image in tile, input gboolean
        # [depth] Pyramid depth, input VipsForeignDzDepth
        # [angle] Rotate image during save, input VipsAngle
        # [container] Pyramid container type, input VipsForeignDzContainer
        # [properties] Write a properties file to the output directory, input gboolean
        # [strip] Strip all metadata from image, input gboolean

        ##
        # :method: pngsave
        # :call-seq:
        #    pngsave(filename) => 
        #
        # Save image to png file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [compression] Compression factor, input gint
        # [interlace] Interlace image, input gboolean
        # [profile] ICC profile to embed, input gchararray
        # [filter] libpng row filter flag(s), input VipsForeignPngFilter
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: pngsave_buffer
        # :call-seq:
        #    pngsave_buffer() => buffer
        #
        # Save image to png buffer.
        #
        # Output:
        # [buffer] Buffer to save to, output VipsBlob
        #
        # Options:
        # [compression] Compression factor, input gint
        # [interlace] Interlace image, input gboolean
        # [profile] ICC profile to embed, input gchararray
        # [filter] libpng row filter flag(s), input VipsForeignPngFilter
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: jpegsave
        # :call-seq:
        #    jpegsave(filename) => 
        #
        # Save image to jpeg file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [Q] Q factor, input gint
        # [profile] ICC profile to embed, input gchararray
        # [optimize-coding] Compute optimal Huffman coding tables, input gboolean
        # [interlace] Generate an interlaced (progressive) jpeg, input gboolean
        # [no-subsample] Disable chroma subsample, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: jpegsave_buffer
        # :call-seq:
        #    jpegsave_buffer() => buffer
        #
        # Save image to jpeg buffer.
        #
        # Output:
        # [buffer] Buffer to save to, output VipsBlob
        #
        # Options:
        # [Q] Q factor, input gint
        # [profile] ICC profile to embed, input gchararray
        # [optimize-coding] Compute optimal Huffman coding tables, input gboolean
        # [interlace] Generate an interlaced (progressive) jpeg, input gboolean
        # [no-subsample] Disable chroma subsample, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: jpegsave_mime
        # :call-seq:
        #    jpegsave_mime() => 
        #
        # Save image to jpeg mime.
        #
        # Options:
        # [Q] Q factor, input gint
        # [profile] ICC profile to embed, input gchararray
        # [optimize-coding] Compute optimal Huffman coding tables, input gboolean
        # [interlace] Generate an interlaced (progressive) jpeg, input gboolean
        # [no-subsample] Disable chroma subsample, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: webpsave
        # :call-seq:
        #    webpsave(filename) => 
        #
        # Save image to webp file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [Q] Q factor, input gint
        # [lossless] enable lossless compression, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: webpsave_buffer
        # :call-seq:
        #    webpsave_buffer() => buffer
        #
        # Save image to webp buffer.
        #
        # Output:
        # [buffer] Buffer to save to, output VipsBlob
        #
        # Options:
        # [Q] Q factor, input gint
        # [lossless] enable lossless compression, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: tiffsave
        # :call-seq:
        #    tiffsave(filename) => 
        #
        # Save image to tiff file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [compression] Compression for this file, input VipsForeignTiffCompression
        # [Q] Q factor, input gint
        # [predictor] Compression prediction, input VipsForeignTiffPredictor
        # [profile] ICC profile to embed, input gchararray
        # [tile] Write a tiled tiff, input gboolean
        # [tile-width] Tile width in pixels, input gint
        # [tile-height] Tile height in pixels, input gint
        # [pyramid] Write a pyramidal tiff, input gboolean
        # [squash] Squash images down to 1 bit, input gboolean
        # [resunit] Resolution unit, input VipsForeignTiffResunit
        # [xres] Horizontal resolution in pixels/mm, input gdouble
        # [yres] Vertical resolution in pixels/mm, input gdouble
        # [bigtiff] Write a bigtiff image, input gboolean
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: fitssave
        # :call-seq:
        #    fitssave(filename) => 
        #
        # Save image to fits file.
        #
        # Input:
        # [filename] Filename to save to, input gchararray
        #
        # Options:
        # [strip] Strip all metadata from image, input gboolean
        # [background] Background value, input VipsArrayDouble

        ##
        # :method: shrink
        # :call-seq:
        #    shrink(xshrink, yshrink) => out
        #
        # Shrink an image.
        #
        # Input:
        # [xshrink] Horizontal shrink factor, input gdouble
        # [yshrink] Vertical shrink factor, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: quadratic
        # :call-seq:
        #    quadratic(coeff) => out
        #
        # Resample an image with a quadratic transform.
        #
        # Input:
        # [coeff] Coefficient matrix, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [interpolate] Interpolate values with this, input VipsInterpolate

        ##
        # :method: affine
        # :call-seq:
        #    affine(matrix) => out
        #
        # Affine transform of an image.
        #
        # Input:
        # [matrix] Transformation matrix, input VipsArrayDouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [interpolate] Interpolate pixels with this, input VipsInterpolate
        # [oarea] Area of output to generate, input VipsArrayInt
        # [odx] Horizontal output displacement, input gdouble
        # [ody] Vertical output displacement, input gdouble
        # [idx] Horizontal input displacement, input gdouble
        # [idy] Vertical input displacement, input gdouble

        ##
        # :method: similarity
        # :call-seq:
        #    similarity() => out
        #
        # Similarity transform of an image.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [interpolate] Interpolate pixels with this, input VipsInterpolate
        # [scale] Scale by this factor, input gdouble
        # [angle] Rotate anticlockwise by this many degrees, input gdouble
        # [odx] Horizontal output displacement, input gdouble
        # [ody] Vertical output displacement, input gdouble
        # [idx] Horizontal input displacement, input gdouble
        # [idy] Vertical input displacement, input gdouble

        ##
        # :method: resize
        # :call-seq:
        #    resize(scale) => out
        #
        # Resize an image.
        #
        # Input:
        # [scale] Scale image by this factor, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [interpolate] Interpolate pixels with this, input VipsInterpolate
        # [idx] Horizontal input displacement, input gdouble
        # [idy] Vertical input displacement, input gdouble

        ##
        # :method: colourspace
        # :call-seq:
        #    colourspace(space) => out
        #
        # Convert to a new colourspace.
        #
        # Input:
        # [space] Destination colour space, input VipsInterpretation
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [source-space] Source colour space, input VipsInterpretation

        ##
        # :method: colourspace
        # :call-seq:
        #    colourspace(space) => out
        #
        # Convert to a new colourspace.
        #
        # Input:
        # [space] Destination colour space, input VipsInterpretation
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [source-space] Source colour space, input VipsInterpretation

        ##
        # :method: Lab2XYZ
        # :call-seq:
        #    Lab2XYZ() => out
        #
        # Transform cielab to xyz.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [temp] Colour temperature, input VipsArrayDouble

        ##
        # :method: XYZ2Lab
        # :call-seq:
        #    XYZ2Lab() => out
        #
        # Transform xyz to lab.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [temp] Colour temperature, input VipsArrayDouble

        ##
        # :method: Lab2LCh
        # :call-seq:
        #    Lab2LCh() => out
        #
        # Transform lab to lch.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LCh2Lab
        # :call-seq:
        #    LCh2Lab() => out
        #
        # Transform lch to lab.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LCh2CMC
        # :call-seq:
        #    LCh2CMC() => out
        #
        # Transform lch to cmc.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: CMC2LCh
        # :call-seq:
        #    CMC2LCh() => out
        #
        # Transform lch to cmc.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: XYZ2Yxy
        # :call-seq:
        #    XYZ2Yxy() => out
        #
        # Transform xyz to yxy.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: Yxy2XYZ
        # :call-seq:
        #    Yxy2XYZ() => out
        #
        # Transform yxy to xyz.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: scRGB2XYZ
        # :call-seq:
        #    scRGB2XYZ() => out
        #
        # Transform scrgb to xyz.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: XYZ2scRGB
        # :call-seq:
        #    XYZ2scRGB() => out
        #
        # Transform xyz to scrgb.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LabQ2Lab
        # :call-seq:
        #    LabQ2Lab() => out
        #
        # Unpack a labq image to float lab.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: Lab2LabQ
        # :call-seq:
        #    Lab2LabQ() => out
        #
        # Transform float lab to labq coding.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LabQ2LabS
        # :call-seq:
        #    LabQ2LabS() => out
        #
        # Unpack a labq image to short lab.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LabS2LabQ
        # :call-seq:
        #    LabS2LabQ() => out
        #
        # Transform short lab to labq coding.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LabS2Lab
        # :call-seq:
        #    LabS2Lab() => out
        #
        # Transform signed short lab to float.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: Lab2LabS
        # :call-seq:
        #    Lab2LabS() => out
        #
        # Transform float lab to signed short.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: rad2float
        # :call-seq:
        #    rad2float() => out
        #
        # Unpack radiance coding to float rgb.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: float2rad
        # :call-seq:
        #    float2rad() => out
        #
        # Transform float rgb to radiance coding.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: LabQ2sRGB
        # :call-seq:
        #    LabQ2sRGB() => out
        #
        # Unpack a labq image to short lab.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: sRGB2scRGB
        # :call-seq:
        #    sRGB2scRGB() => out
        #
        # Convert an srgb image to scrgb.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: scRGB2sRGB
        # :call-seq:
        #    scRGB2sRGB() => out
        #
        # Convert an scrgb image to srgb.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [depth] Output device space depth in bits, input gint

        ##
        # :method: icc_import
        # :call-seq:
        #    icc_import() => out
        #
        # Import from device with icc profile.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [pcs] Set Profile Connection Space, input VipsPCS
        # [intent] Rendering intent, input VipsIntent
        # [embedded] Use embedded input profile, if available, input gboolean
        # [input-profile] Filename to load input profile from, input gchararray

        ##
        # :method: icc_export
        # :call-seq:
        #    icc_export() => out
        #
        # Output to device with icc profile.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [pcs] Set Profile Connection Space, input VipsPCS
        # [intent] Rendering intent, input VipsIntent
        # [output-profile] Filename to load output profile from, input gchararray
        # [depth] Output device space depth in bits, input gint

        ##
        # :method: icc_transform
        # :call-seq:
        #    icc_transform(output-profile) => out
        #
        # Transform between devices with icc profiles.
        #
        # Input:
        # [output-profile] Filename to load output profile from, input gchararray
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [pcs] Set Profile Connection Space, input VipsPCS
        # [intent] Rendering intent, input VipsIntent
        # [embedded] Use embedded input profile, if available, input gboolean
        # [input-profile] Filename to load input profile from, input gchararray
        # [depth] Output device space depth in bits, input gint

        ##
        # :method: dE76
        # :call-seq:
        #    dE76(right) => out
        #
        # Calculate de76.
        #
        # Input:
        # [right] Right-hand input image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: dE00
        # :call-seq:
        #    dE00(right) => out
        #
        # Calculate de00.
        #
        # Input:
        # [right] Right-hand input image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: dECMC
        # :call-seq:
        #    dECMC(right) => out
        #
        # Calculate decmc.
        #
        # Input:
        # [right] Right-hand input image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: maplut
        # :call-seq:
        #    maplut(lut) => out
        #
        # Map an image though a lut.
        #
        # Input:
        # [lut] Look-up table image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [band] apply one-band lut to this band of in, input gint

        ##
        # :method: percent
        # :call-seq:
        #    percent(percent) => threshold
        #
        # Find threshold for percent of pixels.
        #
        # Input:
        # [percent] Percent of pixels, input gdouble
        #
        # Output:
        # [threshold] Threshold above which lie percent of pixels, output gint

        ##
        # :method: stdif
        # :call-seq:
        #    stdif(width, height) => out
        #
        # Statistical difference.
        #
        # Input:
        # [width] Window width in pixels, input gint
        # [height] Window height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [a] Weight of new mean, input gdouble
        # [s0] New deviation, input gdouble
        # [b] Weight of new deviation, input gdouble
        # [m0] New mean, input gdouble

        ##
        # :method: hist_cum
        # :call-seq:
        #    hist_cum() => out
        #
        # Form cumulative histogram.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: hist_match
        # :call-seq:
        #    hist_match(ref) => out
        #
        # Match two histograms.
        #
        # Input:
        # [ref] Reference histogram, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: hist_norm
        # :call-seq:
        #    hist_norm() => out
        #
        # Normalise histogram.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: hist_equal
        # :call-seq:
        #    hist_equal() => out
        #
        # Histogram equalisation.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [band] Equalise with this band, input gint

        ##
        # :method: hist_plot
        # :call-seq:
        #    hist_plot() => out
        #
        # Plot histogram.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: hist_local
        # :call-seq:
        #    hist_local(width, height) => out
        #
        # Local histogram equalisation.
        #
        # Input:
        # [width] Window width in pixels, input gint
        # [height] Window height in pixels, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: hist_ismonotonic
        # :call-seq:
        #    hist_ismonotonic() => monotonic
        #
        # Test for monotonicity.
        #
        # Output:
        # [monotonic] true if in is monotonic, output gboolean

        ##
        # :method: conv
        # :call-seq:
        #    conv(mask) => out
        #
        # Convolution operation.
        #
        # Input:
        # [mask] Input matrix image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [precision] Convolve with this precision, input VipsPrecision
        # [layers] Use this many layers in approximation, input gint
        # [cluster] Cluster lines closer than this in approximation, input gint

        ##
        # :method: compass
        # :call-seq:
        #    compass(mask) => out
        #
        # Convolve with rotating mask.
        #
        # Input:
        # [mask] Input matrix image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [times] Rotate and convolve this many times, input gint
        # [angle] Rotate mask by this much between convolutions, input VipsAngle45
        # [combine] Combine convolution results like this, input VipsCombine
        # [precision] Convolve with this precision, input VipsPrecision
        # [layers] Use this many layers in approximation, input gint
        # [cluster] Cluster lines closer than this in approximation, input gint

        ##
        # :method: convsep
        # :call-seq:
        #    convsep(mask) => out
        #
        # Seperable convolution operation.
        #
        # Input:
        # [mask] Input matrix image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [precision] Convolve with this precision, input VipsPrecision
        # [layers] Use this many layers in approximation, input gint
        # [cluster] Cluster lines closer than this in approximation, input gint

        ##
        # :method: fastcor
        # :call-seq:
        #    fastcor(ref) => out
        #
        # Fast correlation.
        #
        # Input:
        # [ref] Input reference image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: spcor
        # :call-seq:
        #    spcor(ref) => out
        #
        # Spatial correlation.
        #
        # Input:
        # [ref] Input reference image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: sharpen
        # :call-seq:
        #    sharpen() => out
        #
        # Unsharp masking for print.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [radius] Mask radius, input gint
        # [x1] Flat/jaggy threshold, input gdouble
        # [y2] Maximum brightening, input gdouble
        # [y3] Maximum darkening, input gdouble
        # [m1] Slope for flat areas, input gdouble
        # [m2] Slope for jaggy areas, input gdouble

        ##
        # :method: gaussblur
        # :call-seq:
        #    gaussblur(sigma) => out
        #
        # Gaussian blur.
        #
        # Input:
        # [sigma] Sigma of Gaussian, input gdouble
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [min-ampl] Minimum amplitude of Gaussian, input gdouble
        # [precision] Convolve with this precision, input VipsPrecision

        ##
        # :method: fwfft
        # :call-seq:
        #    fwfft() => out
        #
        # Forward fft.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: invfft
        # :call-seq:
        #    invfft() => out
        #
        # Inverse fft.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [real] Output only the real part of the transform, input gboolean

        ##
        # :method: freqmult
        # :call-seq:
        #    freqmult(mask) => out
        #
        # Frequency-domain filtering.
        #
        # Input:
        # [mask] Input mask image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: spectrum
        # :call-seq:
        #    spectrum() => out
        #
        # Make displayable power spectrum.
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: phasecor
        # :call-seq:
        #    phasecor(in2) => out
        #
        # Calculate phase correlation.
        #
        # Input:
        # [in2] Second input image, input VipsImage
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: morph
        # :call-seq:
        #    morph(mask, morph) => out
        #
        # Morphology operation.
        #
        # Input:
        # [mask] Input matrix image, input VipsImage
        # [morph] Morphological operation to perform, input VipsOperationMorphology
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: rank
        # :call-seq:
        #    rank(width, height, index) => out
        #
        # Rank filter.
        #
        # Input:
        # [width] Window width in pixels, input gint
        # [height] Window height in pixels, input gint
        # [index] Select pixel at index, input gint
        #
        # Output:
        # [out] Output image, output VipsImage

        ##
        # :method: countlines
        # :call-seq:
        #    countlines(direction) => nolines
        #
        # Count lines in an image.
        #
        # Input:
        # [direction] Countlines left-right or up-down, input VipsDirection
        #
        # Output:
        # [nolines] Number of lines, output gdouble

        ##
        # :method: labelregions
        # :call-seq:
        #    labelregions() => mask
        #
        # Label regions in an image.
        #
        # Output:
        # [mask] Mask of region labels, output VipsImage
        #
        # Output options:
        # [segments] Number of discrete contigious regions, output gint

        ##
        # :method: draw_rect
        # :call-seq:
        #    draw_rect(ink, left, top, width, height) => image
        #
        # Paint a rectangle on an image.
        #
        # Input:
        # [ink] Colour for pixels, input VipsArrayDouble
        # [left] Rect to fill, input gint
        # [top] Rect to fill, input gint
        # [width] Rect to fill, input gint
        # [height] Rect to fill, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage
        #
        # Options:
        # [fill] Draw a solid object, input gboolean

        ##
        # :method: draw_mask
        # :call-seq:
        #    draw_mask(ink, mask, x, y) => image
        #
        # Draw a mask on an image.
        #
        # Input:
        # [ink] Colour for pixels, input VipsArrayDouble
        # [mask] Mask of pixels to draw, input VipsImage
        # [x] Draw mask here, input gint
        # [y] Draw mask here, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage

        ##
        # :method: draw_line
        # :call-seq:
        #    draw_line(ink, x1, y1, x2, y2) => image
        #
        # Draw a draw_line on an image.
        #
        # Input:
        # [ink] Colour for pixels, input VipsArrayDouble
        # [x1] Start of draw_line, input gint
        # [y1] Start of draw_line, input gint
        # [x2] End of draw_line, input gint
        # [y2] End of draw_line, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage

        ##
        # :method: draw_circle
        # :call-seq:
        #    draw_circle(ink, cx, cy, radius) => image
        #
        # Draw a draw_circle on an image.
        #
        # Input:
        # [ink] Colour for pixels, input VipsArrayDouble
        # [cx] Centre of draw_circle, input gint
        # [cy] Centre of draw_circle, input gint
        # [radius] Radius in pixels, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage
        #
        # Options:
        # [fill] Draw a solid object, input gboolean

        ##
        # :method: draw_flood
        # :call-seq:
        #    draw_flood(ink, x, y) => image
        #
        # Flood-fill an area.
        #
        # Input:
        # [ink] Colour for pixels, input VipsArrayDouble
        # [x] DrawFlood start point, input gint
        # [y] DrawFlood start point, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage
        #
        # Options:
        # [test] Test pixels in this image, input VipsImage
        # [equal] DrawFlood while equal to edge, input gboolean
        #
        # Output options:
        # [left] Left edge of modified area, output gint
        # [top] top edge of modified area, output gint
        # [width] width of modified area, output gint
        # [height] height of modified area, output gint

        ##
        # :method: draw_image
        # :call-seq:
        #    draw_image(sub, x, y) => image
        #
        # Paint an image into another image.
        #
        # Input:
        # [sub] Sub-image to insert into main image, input VipsImage
        # [x] Draw image here, input gint
        # [y] Draw image here, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage
        #
        # Options:
        # [mode] Combining mode, input VipsCombineMode

        ##
        # :method: draw_smudge
        # :call-seq:
        #    draw_smudge(left, top, width, height) => image
        #
        # Blur a rectangle on an image.
        #
        # Input:
        # [left] Rect to fill, input gint
        # [top] Rect to fill, input gint
        # [width] Rect to fill, input gint
        # [height] Rect to fill, input gint
        #
        # Output:
        # [image] Image to draw on, input VipsImage

        ##
        # :method: merge
        # :call-seq:
        #    merge(sec, direction, dx, dy) => out
        #
        # Merge two images.
        #
        # Input:
        # [sec] Secondary image, input VipsImage
        # [direction] Horizontal or vertcial merge, input VipsDirection
        # [dx] Horizontal displacement from sec to ref, input gint
        # [dy] Vertical displacement from sec to ref, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [mblend] Maximum blend size, input gint

        ##
        # :method: mosaic
        # :call-seq:
        #    mosaic(sec, direction, xref, yref, xsec, ysec) => out
        #
        # Mosaic two images.
        #
        # Input:
        # [sec] Secondary image, input VipsImage
        # [direction] Horizontal or vertcial mosaic, input VipsDirection
        # [xref] Position of reference tie-point, input gint
        # [yref] Position of reference tie-point, input gint
        # [xsec] Position of secondary tie-point, input gint
        # [ysec] Position of secondary tie-point, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [hwindow] Half window size, input gint
        # [harea] Half area size, input gint
        # [mblend] Maximum blend size, input gint
        # [bandno] Band to search for features on, input gint
        #
        # Output options:
        # [dx0] Detected integer offset, output gint
        # [dy0] Detected integer offset, output gint
        # [scale1] Detected scale, output gdouble
        # [angle1] Detected rotation, output gdouble
        # [dx1] Detected first-order displacement, output gdouble
        # [dy1] Detected first-order displacement, output gdouble

        ##
        # :method: mosaic1
        # :call-seq:
        #    mosaic1(sec, direction, xr1, yr1, xs1, ys1, xr2, yr2, xs2, ys2) => out
        #
        # First-order mosaic of two images.
        #
        # Input:
        # [sec] Secondary image, input VipsImage
        # [direction] Horizontal or vertcial mosaic, input VipsDirection
        # [xr1] Position of first reference tie-point, input gint
        # [yr1] Position of first reference tie-point, input gint
        # [xs1] Position of first secondary tie-point, input gint
        # [ys1] Position of first secondary tie-point, input gint
        # [xr2] Position of second reference tie-point, input gint
        # [yr2] Position of second reference tie-point, input gint
        # [xs2] Position of second secondary tie-point, input gint
        # [ys2] Position of second secondary tie-point, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [hwindow] Half window size, input gint
        # [harea] Half area size, input gint
        # [search] Search to improve tie-points, input gboolean
        # [interpolate] Interpolate pixels with this, input VipsInterpolate
        # [mblend] Maximum blend size, input gint
        # [bandno] Band to search for features on, input gint

        ##
        # :method: match
        # :call-seq:
        #    match(sec, xr1, yr1, xs1, ys1, xr2, yr2, xs2, ys2) => out
        #
        # First-order match of two images.
        #
        # Input:
        # [sec] Secondary image, input VipsImage
        # [xr1] Position of first reference tie-point, input gint
        # [yr1] Position of first reference tie-point, input gint
        # [xs1] Position of first secondary tie-point, input gint
        # [ys1] Position of first secondary tie-point, input gint
        # [xr2] Position of second reference tie-point, input gint
        # [yr2] Position of second reference tie-point, input gint
        # [xs2] Position of second secondary tie-point, input gint
        # [ys2] Position of second secondary tie-point, input gint
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [hwindow] Half window size, input gint
        # [harea] Half area size, input gint
        # [search] Search to improve tie-points, input gboolean
        # [interpolate] Interpolate pixels with this, input VipsInterpolate

        ##
        # :method: globalbalance
        # :call-seq:
        #    globalbalance() => out
        #
        # Global balance an image mosaic.
        #
        # Output:
        # [out] Output image, output VipsImage
        #
        # Options:
        # [gamma] Image gamma, input gdouble
        # [int-output] Integer output, input gboolean

    end
end
