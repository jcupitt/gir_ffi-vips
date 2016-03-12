module Vips

    class Operation

        # we need to override new: Vips::Operation.new will return a subclass of
        # operation, not an operation itself
        setup_method :new
        def self.new(name)
            _v2 = GirFFI::InPointer.from :utf8, name
            _v3 = Vips::Lib.vips_operation_new _v2
            _v1 = Vips::Operation.wrap(_v3)

            return _v1
        end

        # Fetch arg list, remove boring ones, sort into priority order.
        def get_args
            object_class = GObject::object_class_from_instance self
            io_bits = Vips::ArgumentFlags[:input] | Vips::ArgumentFlags[:output]
            props = object_class.list_properties.select do |prop|
                flags = get_argument_flags prop.get_name
                flags = Vips::ArgumentFlags.to_native flags, 1
                (flags & io_bits != 0) &&
                    (flags & Vips::ArgumentFlags[:deprecated] == 0)
            end
            args = props.map {|x| Argument.new self, x}
            args.sort! {|a, b| a.priority - b.priority}
        end
    end

end
