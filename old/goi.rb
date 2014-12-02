#!/usr/bin/ruby

require 'gobject-introspection'

# copy-pasted from 
# https://github.com/ruby-gnome2/ruby-gnome2/blob/master/clutter/lib/clutter.rb
# without much understanding

module Vips

    class << self
        def const_missing(name)
            init()
            if const_defined?(name)
                const_get(name)
            else
                super
            end
        end

        def init(argv=[])
            puts "in Vips module init"
            class << self
                remove_method(:init)
                remove_method(:const_missing)
            end
            loader = Loader.new(self, argv)
            loader.load("Vips")
        end
    end

    class Loader < GObjectIntrospection::Loader
        class InitError < StandardError
        end

        def initialize(base_module, init_arguments)
            super(base_module)
            @init_arguments = init_arguments
            @key_constants = {}
            @other_constant_infos = []
            @event_infos = []
        end

        private
        def pre_load(repository, namespace)
            init = repository.find(namespace, "init")
            arguments = [
                [$0] + @init_arguments,
            ]
            error, returned_arguments = init.invoke(:arguments => arguments)
            @init_arguments.replace(returned_arguments[1..-1])
            if error.to_i <= 0
                raise InitError, "failed to initialize Vips: #{error.name}"
                end
                @keys_module = Module.new
                @base_module.const_set("Keys", @keys_module)
                @threads_module = Module.new
                @base_module.const_set("Threads", @threads_module)
                @feature_module = Module.new
                @base_module.const_set("Feature", @feature_module)
        end

        def post_load(repository, namespace)
            @other_constant_infos.each do |constant_info|
                name = constant_info.name
                next if @key_constants.has_key?("KEY_#{name}")
                @base_module.const_set(name, constant_info.value)
            end
            load_events
        end

        def load_events
            @event_infos.each do |event_info|
                define_struct(event_info, :parent => Event)
            end
            event_map = {
                EventType::KEY_PRESS => KeyEvent,
                EventType::KEY_RELEASE => KeyEvent,
                EventType::MOTION => MotionEvent,
                EventType::ENTER => CrossingEvent,
                EventType::LEAVE => CrossingEvent,
                EventType::BUTTON_PRESS => ButtonEvent,
                EventType::BUTTON_RELEASE => ButtonEvent,
                EventType::SCROLL => ScrollEvent,
                EventType::STAGE_STATE => StageStateEvent,
                EventType::TOUCH_UPDATE => TouchEvent,
                EventType::TOUCH_END => TouchEvent,
                EventType::TOUCH_CANCEL => TouchEvent,
            }
            self.class.register_boxed_class_converter(Event.gtype) do |event|
                event_map[event.type] || Event
            end
        end

        def load_struct_info(info)
            if info.name.end_with?("Event")
                @event_infos << info
            else
                super
            end
        end

        def load_function_info(info)
            name = info.name
            case name
            when "init"
                # ignore
            when /\Athreads_/
                define_module_function(@threads_module, $POSTMATCH, info)
            when /\Afeature_/
                method_name = rubyish_method_name(info, :prefix => "feature_")
                case method_name
                when "available"
                    method_name = "#{method_name}?"
                end
                define_module_function(@feature_module, method_name, info)
            else
                super
            end
        end

        def load_constant_info(info)
            case info.name
            when /\AKEY_/
                @key_constants[info.name] = true
                @keys_module.const_set(info.name, info.value)
            else
                @other_constant_infos << info
            end
        end
    end
end

