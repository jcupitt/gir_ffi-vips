# This module provides a set of overrides for the vips image processing library
# used via the gir_ffi gem. 
#
# Author::    John Cupitt  (mailto:jcupitt@gmail.com)
# License::   MIT

# about as crude as you could get
$debug = true

def log str # :nodoc:
    if $debug
        puts str
    end
end

# This class is used internally to convert Ruby values to arguments to libvips
# operations. 
class Argument # :nodoc:
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

            value = value.map {|x| imageize match_image, x}

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

    public

    def set_value(match_image, value)
        # insert some boxing code

        # array-ize
        value = Argument::arrayize prop.value_type, value

        # enums must be unwrapped, not sure why, they are wrapped 
        # automatically
        if prop.is_a? GObject::ParamSpecEnum
            enum_class = GObject::type_class_ref prop.value_type
            # not sure what to do here
            value = prop.to_native value, 1
        end

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
        value = @op.property(@name).get_value

        # unwrap
        [Vips::Blob, Vips::ArrayDouble, Vips::ArrayImage, 
            Vips::ArrayInt].each do |cls|
            if value.is_a? cls
                value = value.get
            end
        end

        value
    end

    def description
        direction = @flags & Vips::ArgumentFlags[:input] != 0 ? 
            "input" : "output"

        result = @name
        result += " " * (15 - @name.length) + " -- " + @prop.get_blurb
        result += ", " + direction 
        result += " " + GObject::type_name(@prop.value_type)
    end

end

# we add methods to these below, so we must load first
Vips::load_class :Operation
Vips::load_class :Image

# This module provides a set of overrides for the vips image processing library
# used via the gir_ffi gem. 

module Vips

    TYPE_ARRAY_INT = GObject::type_from_name "VipsArrayInt"
    TYPE_ARRAY_DOUBLE = GObject::type_from_name "VipsArrayDouble"
    TYPE_ARRAY_IMAGE = GObject::type_from_name "VipsArrayImage"
    TYPE_BLOB = GObject::type_from_name "VipsBlob"
    TYPE_IMAGE = GObject::type_from_name "VipsImage"
    TYPE_OPERATION = GObject::type_from_name "VipsOperation"

    public

    # If @msg is not supplied, grab and clear the vips error buffer instead. 

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

        # call
        op2 = Vips::cache_operation_build op
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

    # call-seq:
    #   call( operation_name, required_arg1, ..., required_argn, optional_args ) => result
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
    # to run the vips_invert() operator.
    #
    # There are also a set of operator overloads and some convenience functions,
    # see Vips::Image. 
    #
    # If the operator needs a vector constant, ::call will turn a scalar into a
    # vector for you. So for x.linear(a, b), which calculates x * a + b where a
    # and b are vector constants, you can write:
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

    public
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
        # image with height 1. Use #scale and #offset to set the scale and
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
            round Vips::OperationRound[:floor]
        end

        # Return the smallest integral value not less than the argument.
        def ceil
            round Vips::OperationRound[:ceil]
        end

        # Return the nearest integral value.
        def rint
            round Vips::OperationRound[:rint]
        end

        # call-seq:
        #   bandsplit => [image]
        #
        # Split an n-band image into n separate images.
        def bandsplit
            (0...bands).map {|i| extract_band(i)}
        end

        # call-seq:
        #   bandjoin(image) => image
        #   bandjoin(const_array) => image
        #   bandjoin(image_array) => image
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
            complexget Vips::OperationComplexget[:real]
        end

        # Return the imaginary part of a complex image.
        def imag
            complexget Vips::OperationComplexget[:imag]
        end

        # Return an image converted to polar coordinates.
        def polar
            complex Vips::OperationComplex[:polar]
        end

        # Return an image converted to rectangular coordinates.
        def rect
            complex Vips::OperationComplex[:rect] 
        end

        # Return the complex conjugate of an image.
        def conj
            complex Vips::OperationComplex[:conj] 
        end

        # Return the sine of an image in degrees.
        def sin
            math Vips::OperationMath[:sin] 
        end

        # Return the cosine of an image in degrees.
        def cos
            math Vips::OperationMath[:cos]
        end

        # Return the tangent of an image in degrees.
        def tan
            math Vips::OperationMath[:tan]
        end

        # Return the inverse sine of an image in degrees.
        def asin
            math Vips::OperationMath[:asin]
        end

        # Return the inverse cosine of an image in degrees.
        def acos
            math Vips::OperationMath[:acos]
        end

        # Return the inverse tangent of an image in degrees.
        def atan
            math Vips::OperationMath[:atan]
        end

        # Return the natural log of an image.
        def log
            math Vips::OperationMath[:log]
        end

        # Return the log base 10 of an image.
        def log10
            math Vips::OperationMath[:log10]
        end

        # Return e ** pixel.
        def exp
            math Vips::OperationMath[:exp]
        end

        # Return 10 ** pixel.
        def exp10
            math Vips::OperationMath[:exp10]
        end

        # Select pixels from #th if #self is non-zero and from #el if
        # #self is zero. Use the :blend option to fade smoothly 
        # between #th and #el. 
        def ifthenelse(th, el, *args) 
            match_image = [th, el, self].find {|x| x.is_a? Vips::Image}

            if not th.is_a? Vips.Image
                th = imageize match_image, th
            end
            if not el.is_a? Vips::Image
                el = imageize match_image, el
            end

            call_base "ifthenelse", self, "", [th, el] + args
        end

    end

    def self.generate_rdoc
        # we have synonyms: don't generate twice
        generated_operations = {}

        def generate_class gtype
            cls = GObject::type_class_ref gtype

            # we need some way to get from the gtype to the matching ruby class
            # that wraps it
 
            (GObject::type_children gtype).each do |x|
                generate_class x
            end
        end

        generate_class TYPE_OPERATION
    end

end

